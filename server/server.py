"""Receives original photo/video files from the PhotoDrop iPhone app.

Two stages, like Copy-iPhonePhotos v5: phone -> laptop holding folder -> home
desktop share. A holding copy is deleted only after the copy on the share has
been read back and its SHA-256 matches.

Binds to localhost only; `tailscale serve` is the sole way in, and it sets the
Tailscale-User-Login header that authenticates the caller.
"""

import hashlib
import logging
import os
import re
import shutil
import sqlite3
import threading
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request

ROOT = Path(os.environ.get("PHOTODROP_ROOT", Path.home() / "PhotoDrop"))
HOLDING = ROOT / "holding"
DB_PATH = ROOT / "photodrop.db"
ALLOWED_USER = (ROOT / "allowed_user.txt").read_text().strip()
DEST = Path((ROOT / "destination.txt").read_text().strip())
MIN_FREE_BYTES = 10 * 1024**3
MOVE_INTERVAL = float(os.environ.get("PHOTODROP_MOVE_INTERVAL", 20))
INDEX_INTERVAL = 3600

MONTH_RE = re.compile(r"^\d{4}(0[1-9]|1[0-2])$")
# Filenames become paths on Windows, so only what Windows treats as one plain file gets through.
NAME_RE = re.compile(r'^(?!\.)(?!(?:con|prn|aux|nul|com\d|lpt\d)(?:\.|$))[^\\/:*?"<>|\x00-\x1f]{1,200}(?<![. ])$', re.I)
log = logging.getLogger("photodrop")


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    HOLDING.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(
            """CREATE TABLE IF NOT EXISTS files (
                key TEXT PRIMARY KEY, name TEXT, size INTEGER, sha256 TEXT, month TEXT, mtime REAL,
                state TEXT, holding_path TEXT, dest_path TEXT, received_at REAL, verified_at REAL, error TEXT)"""
        )
        conn.execute("CREATE TABLE IF NOT EXISTS archive (key TEXT PRIMARY KEY)")
        conn.execute("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v REAL)")


def file_key(name: str, size: int) -> str:
    return f"{name.lower()}|{size}"  # same "already copied" rule as Copy-iPhonePhotos


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def year_dir(year: str) -> Path:
    """Reuse a folder like 'F. 2026'; only a year with none gets a new one."""
    pattern = re.compile(rf"(^|\D){year}$")
    for entry in os.scandir(DEST):
        if entry.is_dir() and pattern.search(entry.name):
            return Path(entry.path)
    return DEST / year


def move_one(row: sqlite3.Row) -> None:
    source = Path(row["holding_path"])
    folder = year_dir(row["month"][:4]) / f"{row['month']}_a"
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / row["name"]
    if target.exists() and (target.stat().st_size != row["size"] or sha256_file(target) != row["sha256"]):
        # Same name, different contents: keep both, never replace what's in the archive.
        original = Path(row["name"])
        target = folder / f"{original.stem}_{row['sha256'][:8]}{original.suffix}"
    if not target.exists():
        part = target.with_name(f"{target.name}.{uuid.uuid4().hex}.part")
        try:
            shutil.copyfile(source, part)
            if sha256_file(part) != row["sha256"]:
                raise OSError("checksum mismatch after copying to the desktop")
            os.utime(part, (row["mtime"], row["mtime"]))
            os.rename(part, target)
        finally:
            part.unlink(missing_ok=True)
    if sha256_file(target) != row["sha256"]:
        raise OSError("checksum mismatch reading back from the desktop")
    # Record first: a crash here leaves a spare laptop copy, never a lost file.
    with db() as conn:
        conn.execute(
            "UPDATE files SET state='verified', dest_path=?, verified_at=?, holding_path=NULL, error=NULL WHERE key=?",
            (str(target), time.time(), row["key"]),
        )
    source.unlink(missing_ok=True)


def index_archive() -> None:
    keys = []
    for folder, _, names in os.walk(DEST):
        for name in names:
            if not name.endswith(".part"):
                try:
                    keys.append((file_key(name, os.path.getsize(os.path.join(folder, name))),))
                except OSError:
                    pass
    # An empty walk from a share that just vanished must not wipe the index.
    if keys or DEST.is_dir():
        with db() as conn:
            conn.execute("DELETE FROM archive")
            conn.executemany("INSERT OR IGNORE INTO archive VALUES (?)", keys)
            conn.execute("INSERT OR REPLACE INTO meta VALUES ('indexed_at', ?)", (time.time(),))


def mover_pass(last_index: float) -> float:
    if not DEST.is_dir():
        return last_index
    if time.time() - last_index > INDEX_INTERVAL:
        index_archive()
        last_index = time.time()
    with db() as conn:
        rows = conn.execute("SELECT * FROM files WHERE state='holding' ORDER BY received_at").fetchall()
    for row in rows:
        try:
            move_one(row)
        except OSError as error:  # share dropped or file problem: the holding copy stays for the next pass
            log.warning("move failed for %s: %s", row["name"], error)
            with db() as conn:
                conn.execute("UPDATE files SET error=? WHERE key=?", (str(error), row["key"]))
            if not DEST.is_dir():
                break
    return last_index


def mover_loop() -> None:
    last_index = 0.0
    while True:
        try:
            last_index = mover_pass(last_index)
        except Exception:
            log.exception("mover pass failed")
        time.sleep(MOVE_INTERVAL)


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    threading.Thread(target=mover_loop, daemon=True).start()
    yield


app = FastAPI(lifespan=lifespan)


def check_user(request: Request) -> None:
    if request.headers.get("tailscale-user-login") != ALLOWED_USER:
        raise HTTPException(403, "not allowed")


@app.get("/manifest")
def manifest(request: Request) -> dict:
    check_user(request)
    with db() as conn:
        files = conn.execute("SELECT key, state, size, error FROM files").fetchall()
        archive = [r["key"] for r in conn.execute("SELECT key FROM archive")]
        indexed = conn.execute("SELECT v FROM meta WHERE k='indexed_at'").fetchone()
    waiting = [f for f in files if f["state"] == "holding"]
    return {
        "verified": [f["key"] for f in files if f["state"] == "verified"],
        "holding": [f["key"] for f in waiting],
        "archive": archive,
        "archive_indexed": indexed is not None,
        "desktop_online": DEST.is_dir(),
        "holding_bytes": sum(f["size"] for f in waiting),
        "move_error": next((f["error"] for f in waiting if f["error"]), None),
        "laptop_free_bytes": shutil.disk_usage(ROOT).free,
    }


@app.put("/file")
async def put_file(request: Request, name: str, month: str, sha256: str, mtime: float) -> dict:
    check_user(request)
    if not NAME_RE.match(name) or ".." in name or name.endswith(".part") or not MONTH_RE.match(month):
        raise HTTPException(400, "bad name or month")
    if shutil.disk_usage(ROOT).free < MIN_FREE_BYTES:
        raise HTTPException(507, "laptop disk nearly full")

    folder = HOLDING / f"{month}_a"
    folder.mkdir(parents=True, exist_ok=True)
    held = folder / f"{sha256.lower()[:16]}_{name}"
    part = folder / f"{uuid.uuid4().hex}.part"
    digest = hashlib.sha256()
    size = 0
    try:
        with part.open("wb") as f:
            async for chunk in request.stream():
                f.write(chunk)
                digest.update(chunk)
                size += len(chunk)
        if digest.hexdigest() != sha256.lower():
            raise HTTPException(422, "checksum mismatch")
        key = file_key(name, size)
        with db() as conn:
            known = conn.execute("SELECT state FROM files WHERE key=?", (key,)).fetchone()
            if known:
                return {"key": key, "state": known["state"]}
            if conn.execute("SELECT 1 FROM archive WHERE key=?", (key,)).fetchone():
                return {"key": key, "state": "archive"}
            os.replace(part, held)
            conn.execute(
                "INSERT INTO files (key, name, size, sha256, month, mtime, state, holding_path, received_at) "
                "VALUES (?, ?, ?, ?, ?, ?, 'holding', ?, ?)",
                (key, name, size, sha256.lower(), month, mtime, str(held), time.time()),
            )
        os.utime(held, (mtime, mtime))
        return {"key": key, "state": "holding"}
    finally:
        part.unlink(missing_ok=True)
