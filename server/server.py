"""Receives original photo/video files from the PhotoDrop iPhone app.

Two stages, like Copy-iPhonePhotos v5: phone -> laptop holding folder -> home
desktop share. A holding copy is deleted only after the copy on the share has
been read back and its SHA-256 matches.

Two ways in: `tailscale serve` to the localhost listener, which sets the
Tailscale-User-Login header that authenticates the caller; and run.py's HTTPS
listener on the home network, where a phone paired by QR code sends its token.
"""

import hashlib
import hmac
import html
import secrets
import socket
import subprocess
import logging
import os
import re
import shutil
import sqlite3
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path

import segno
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse

ROOT = Path(os.environ.get("PHOTODROP_ROOT", Path.home() / "PhotoDrop"))
# Where files wait until the final folder is reachable; chosen on the settings page.
HOLDING = Path((ROOT / "holding.txt").read_text().strip()) if (ROOT / "holding.txt").exists() else ROOT / "holding"
DB_PATH = ROOT / "photodrop.db"
ALLOWED_USER = (ROOT / "allowed_user.txt").read_text().strip()
DEST = Path((ROOT / "destination.txt").read_text().strip())
MIN_FREE_BYTES = 10 * 1024**3
MOVE_INTERVAL = float(os.environ.get("PHOTODROP_MOVE_INTERVAL", 20))
INDEX_INTERVAL = 3600
MOVE_WORKERS = 4
LAN_PORT = 8865
CERT, CERT_KEY = ROOT / "tls.crt", ROOT / "tls.key"
PAIR_SECONDS = 300
PAIR_TRIES = 5
pairing: dict = {}  # the one live code: {"code", "expires", "tries"}
reindex_requested = threading.Event()

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
        # Only token hashes are kept, so a copied database can't be used to pose as a phone.
        conn.execute("CREATE TABLE IF NOT EXISTS devices (token_hash TEXT PRIMARY KEY, name TEXT, paired_at REAL, last_seen REAL)")


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
    copied = not target.exists()
    if copied:
        part = target.with_name(f"{target.name}.{uuid.uuid4().hex}.part")
        try:
            shutil.copyfile(source, part)
            if sha256_file(part) != row["sha256"]:
                raise OSError("checksum mismatch after copying to the desktop")
            os.utime(part, (row["mtime"], row["mtime"]))
            os.rename(part, target)
        finally:
            part.unlink(missing_ok=True)
    # A fresh copy was already read back as the .part; reading it again over the share doubles the time.
    if not copied and sha256_file(target) != row["sha256"]:
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
    if keys or os.path.isdir(DEST):
        with db() as conn:
            conn.execute("DELETE FROM archive")
            conn.executemany("INSERT OR IGNORE INTO archive VALUES (?)", keys)
            conn.execute("INSERT OR REPLACE INTO meta VALUES ('indexed_at', ?)", (time.time(),))


def index_loop() -> None:
    # Its own thread: walking ~80,000 files on a slow share takes minutes and must not hold up copying.
    last_index = 0.0
    while True:
        if os.path.isdir(DEST) and (reindex_requested.is_set() or time.time() - last_index > INDEX_INTERVAL):
            reindex_requested.clear()
            try:
                index_archive()
                last_index = time.time()
            except Exception:
                log.exception("archive index failed")
        reindex_requested.wait(MOVE_INTERVAL)


def mover_pass() -> None:
    if not os.path.isdir(DEST):
        return
    with db() as conn:
        rows = conn.execute("SELECT * FROM files WHERE state='holding' ORDER BY received_at").fetchall()
    # Same name in the same month waits for the next pass, so two copies never race for one target name.
    seen, batch = set(), []
    for row in rows:
        if (row["month"], row["name"].lower()) not in seen:
            seen.add((row["month"], row["name"].lower()))
            batch.append(row)

    def attempt(row: sqlite3.Row) -> None:
        if not os.path.isdir(DEST):
            return
        try:
            move_one(row)
        except OSError as error:  # share dropped or file problem: the holding copy stays for the next pass
            log.warning("move failed for %s: %s", row["name"], error)
            with db() as conn:
                conn.execute("UPDATE files SET error=? WHERE key=?", (str(error), row["key"]))

    # Several at once: one file at a time leaves the share idle between copy, read-back and rename.
    with ThreadPoolExecutor(MOVE_WORKERS) as pool:
        list(pool.map(attempt, batch))


def mover_loop() -> None:
    while True:
        try:
            mover_pass()
        except Exception:
            log.exception("mover pass failed")
        time.sleep(MOVE_INTERVAL)


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    threading.Thread(target=mover_loop, daemon=True).start()
    threading.Thread(target=index_loop, daemon=True).start()
    yield


app = FastAPI(lifespan=lifespan)


def ensure_cert() -> str:
    """Self-signed certificate for the home-network listener; returns its SHA-256, which the QR code carries."""
    import datetime

    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    if not CERT.exists():
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "PhotoDrop")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (
            x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now)
            .not_valid_after(now + datetime.timedelta(days=3650)).sign(key, hashes.SHA256())
        )
        CERT_KEY.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        CERT.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    der = x509.load_pem_x509_certificate(CERT.read_bytes()).public_bytes(serialization.Encoding.DER)
    return hashlib.sha256(der).hexdigest()


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def check_user(request: Request) -> None:
    token = request.headers.get("x-photodrop-token")
    if token:
        with db() as conn:
            if conn.execute("UPDATE devices SET last_seen=? WHERE token_hash=?", (time.time(), token_hash(token))).rowcount:
                return
        raise HTTPException(403, "This phone was unpaired. Pair it again from the laptop.")
    # The header is only trustworthy on the localhost listener, where tailscale serve sets it.
    if request.url.scheme != "http" or request.headers.get("tailscale-user-login") != ALLOWED_USER:
        raise HTTPException(403, "not allowed")


def check_local(request: Request) -> None:
    """Pairing admin: only someone at the laptop itself, not the home network or the tailnet."""
    if request.url.scheme != "http" or request.client.host != "127.0.0.1" or request.headers.get("tailscale-user-login"):
        raise HTTPException(403, "Open this on the laptop itself.")


def lan_ip() -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect(("192.0.2.1", 9))  # sends nothing; just picks the interface the home network is on
        return s.getsockname()[0]


def wifi_name() -> str:
    try:
        out = subprocess.run(["netsh", "wlan", "show", "interfaces"], capture_output=True, text=True, timeout=5,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
        return next(line.split(":", 1)[1].strip() for line in out.splitlines() if line.strip().startswith("SSID"))
    except (OSError, StopIteration, subprocess.SubprocessError):
        return "not on Wi-Fi (cable or unknown)"


def ago(t: float) -> str:
    seconds = time.time() - t
    if seconds < 60:
        return "<b class=on>â— Connected now</b>"
    for size, unit in ((86400, "day"), (3600, "hour"), (60, "minute")):
        if seconds >= size:
            n = int(seconds // size)
            return f"last seen {n} {unit}{'s' if n > 1 else ''} ago"


@app.get("/pair", response_class=HTMLResponse)
def pair_page(request: Request) -> str:
    check_local(request)
    # The page refreshes itself, so keep a live code instead of replacing it mid-scan.
    if not pairing.get("code") or time.time() > pairing["expires"] - 30:
        pairing.update(code=f"{secrets.randbelow(10**6):06d}", expires=time.time() + PAIR_SECONDS, tries=0)
    address = f"https://{lan_ip()}:{LAN_PORT}"
    link = f"photodrop://pair?u={address}&c={pairing['code']}&f={ensure_cert()}"
    with db() as conn:
        devices = conn.execute("SELECT token_hash, name, paired_at, last_seen FROM devices ORDER BY paired_at").fetchall()
        waiting = conn.execute("SELECT COUNT(*), COALESCE(SUM(size), 0) FROM files WHERE state='holding'").fetchone()
    phones = "".join(
        f"<div class=phone><div><b>{html.escape(d['name'])}</b><span>{ago(d['last_seen'])} Â· paired "
        f"{time.strftime('%d %b %Y', time.localtime(d['paired_at']))}</span></div>"
        f"<form method=post action='/unpair?token_hash={d['token_hash']}'><button class=quiet>Unpair</button></form></div>"
        for d in devices
    ) or "<p class=muted>No phones yet. Scan the code to pair one.</p>"
    reachable = os.path.isdir(DEST)
    return f"""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width"><meta http-equiv=refresh content=10>
<title>PhotoDrop</title>
<style>
:root{{--bg:#f4f5f7;--card:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--accent:#0a84ff;--ok:#1f9d55;--warn:#c27c0e}}
@media (prefers-color-scheme:dark){{:root{{--bg:#111214;--card:#1c1c1f;--text:#f2f2f7;--muted:#98989f;--line:#2c2c30;--accent:#409cff;--ok:#30d158;--warn:#ffb340}}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}}
header{{display:flex;justify-content:space-between;align-items:center;gap:1rem;flex-wrap:wrap;max-width:1100px;margin:0 auto;padding:1.5rem 1.5rem .5rem}}
h1{{font-size:1.5rem;margin:0}} h2{{font-size:1rem;margin:0 0 .75rem}}
.pill{{background:var(--card);border:1px solid var(--line);border-radius:999px;padding:.35rem .9rem;color:var(--muted)}}
.pill b{{color:var(--text)}}
main{{display:grid;grid-template-columns:minmax(300px,380px) 1fr;gap:1.25rem;max-width:1100px;margin:0 auto;padding:1rem 1.5rem 2rem}}
@media (max-width:760px){{main{{grid-template-columns:1fr}}}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:1.25rem 1.4rem}}
.stack{{display:grid;gap:1.25rem;align-content:start}}
.qr{{background:#fff;border-radius:12px;padding:.75rem;display:flex;justify-content:center}}
.qr svg{{width:100%;height:auto;max-width:300px}}
.code{{font:600 2.2rem/1.2 ui-monospace,Consolas,monospace;letter-spacing:.35rem;text-align:center;margin:.75rem 0 .25rem}}
.muted,span{{color:var(--muted)}} small{{color:var(--muted)}}
.addr{{text-align:center;font-family:ui-monospace,Consolas,monospace}}
.phone{{display:flex;justify-content:space-between;align-items:center;gap:1rem;padding:.6rem 0;border-top:1px solid var(--line)}}
.phone:first-of-type{{border-top:0}} .phone span,.folder span{{display:block;font-size:.88rem}}
.on{{color:var(--ok);font-weight:600}}
.folder{{display:flex;justify-content:space-between;align-items:center;gap:1rem;padding:.75rem 0;border-top:1px solid var(--line)}}
.folder:first-of-type{{border-top:0}} .folder div{{min-width:0}}
code{{display:block;overflow-wrap:anywhere;font-size:.88rem;margin-top:.15rem}}
.warn{{color:var(--warn);font-size:.88rem}}
button{{font:inherit;border:0;border-radius:10px;padding:.5rem 1rem;background:var(--accent);color:#fff;cursor:pointer;white-space:nowrap}}
button.quiet{{background:transparent;color:var(--muted);border:1px solid var(--line)}}
form{{margin:0}}
</style>
<header><h1>PhotoDrop</h1>
<div class=pill>Wi-Fi <b>{html.escape(wifi_name())}</b> Â· {lan_ip()}</div></header>
<main>
<section class=card>
<h2>Pair a phone</h2>
<p class=muted>On the phone: PhotoDrop â†’ Settings â†’ Pair with laptop. It must be on the same Wi-Fi.</p>
<div class=qr>{segno.make(link, error="m").svg_inline(scale=6)}</div>
<div class=code>{pairing['code']}</div>
<div class=addr>{address}</div>
<p><small>Or type the address and code. Each code works once; a new one appears after it's used or after 5 minutes.</small></p>
</section>
<div class=stack>
<section class=card><h2>Phones</h2>{phones}</section>
<section class=card><h2>Folders</h2>
<div class=folder><div><b>Final folder</b><span>Where photos end up</span><code>{html.escape(str(DEST))}</code>
{"" if reachable else "<div class=warn>Not reachable right now. Files wait on this laptop until it is.</div>"}</div>
<form method=post action="/choose?which=final"><button>Chooseâ€¦</button></form></div>
<div class=folder><div><b>Waiting folder</b><span>{waiting[0]} file{"" if waiting[0] == 1 else "s"} waiting Â· {waiting[1] / 1024**3:.1f} GB</span>
<code>{html.escape(str(HOLDING))}</code></div>
<form method=post action="/choose?which=waiting"><button class=quiet>Chooseâ€¦</button></form></div>
</section>
<p><small>Updates every 10 seconds. This page only opens on this laptop.</small></p>
</div>
</main>"""


def pick_folder(title: str, start: Path) -> str:
    """The standard Windows folder picker, shown on the laptop's screen."""
    import tkinter
    from tkinter import filedialog

    root = tkinter.Tk()
    root.withdraw()
    root.attributes("-topmost", True)  # the receiver has no window, so the picker would open behind the browser
    try:
        return filedialog.askdirectory(parent=root, title=title, initialdir=start if start.exists() else Path.home())
    finally:
        root.destroy()


@app.post("/choose")
def choose(request: Request, which: str) -> RedirectResponse:
    global HOLDING
    check_local(request)
    if which == "final":
        picked = pick_folder("Where should PhotoDrop put your photos?", DEST)
        if picked:
            apply_destination(str(Path(picked)))
    elif which == "waiting":
        picked = pick_folder("Where should files wait until the final folder is reachable?", HOLDING)
        if picked:
            new = Path(picked)
            new.mkdir(parents=True, exist_ok=True)
            # Files already waiting keep their saved paths and still move; only new ones go here.
            (ROOT / "holding.txt").write_text(str(new))
            HOLDING = new
    return RedirectResponse("/pair", 303)


@app.post("/pair")
async def pair(request: Request) -> dict:
    body = await request.json()
    code, name = str(body.get("code", "")), str(body.get("name", "Phone"))[:60]
    if not pairing.get("code") or time.time() > pairing["expires"] or pairing["tries"] >= PAIR_TRIES:
        pairing.clear()
        raise HTTPException(403, "No pairing code is live. Reload the pairing page on the laptop.")
    pairing["tries"] += 1  # five guesses at a million codes, then the code is gone
    if not hmac.compare_digest(code, pairing["code"]):
        raise HTTPException(403, "Wrong code.")
    pairing.clear()  # one phone per code
    token = secrets.token_urlsafe(32)
    with db() as conn:
        conn.execute("INSERT INTO devices VALUES (?, ?, ?, ?)", (token_hash(token), name, time.time(), time.time()))
    return {"token": token}


@app.post("/unpair")
def unpair(request: Request, token_hash: str) -> RedirectResponse:
    check_local(request)
    with db() as conn:
        conn.execute("DELETE FROM devices WHERE token_hash=?", (token_hash,))
    return RedirectResponse("/pair", 303)


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
        "desktop_online": os.path.isdir(DEST),
        "destination": str(DEST),
        "holding_bytes": sum(f["size"] for f in waiting),
        "move_error": next((f["error"] for f in waiting if f["error"]), None),
        "laptop_free_bytes": shutil.disk_usage(ROOT).free,
    }


@app.post("/still-there")
async def still_there(request: Request) -> list[str]:
    """Which of these keys are verified and on the desktop right now. The phone asks before deleting."""
    check_user(request)
    keys = await request.json()
    with db() as conn:
        rows = [
            conn.execute("SELECT key, size, dest_path FROM files WHERE key=? AND state='verified'", (k,)).fetchone()
            for k in keys
        ]
    present = []
    for row in rows:
        try:
            if row and os.path.getsize(row["dest_path"]) == row["size"]:
                present.append(row["key"])
        except OSError:
            pass
    return present


@app.get("/media")
def media(request: Request, key: str) -> FileResponse:
    """A transferred file, for viewing from History. The path comes from the database, never the request."""
    check_user(request)
    with db() as conn:
        row = conn.execute("SELECT name, holding_path, dest_path FROM files WHERE key=?", (key,)).fetchone()
    path = row and (row["holding_path"] or row["dest_path"])
    if not path or not os.path.isfile(path):
        raise HTTPException(404, "not available right now")
    return FileResponse(path, filename=row["name"], content_disposition_type="inline")


@app.get("/history")
def history(request: Request, limit: int = 300) -> list[dict]:
    check_user(request)
    with db() as conn:
        rows = conn.execute(
            "SELECT key, name, size, state, dest_path, received_at, verified_at, error FROM files "
            "ORDER BY COALESCE(verified_at, received_at) DESC LIMIT ?",
            (min(limit, 1000),),
        ).fetchall()
    return [dict(r) for r in rows]


@app.post("/destination")
def set_destination(request: Request, path: str) -> dict:
    check_user(request)
    return apply_destination(path)


def apply_destination(path: str) -> dict:
    global DEST
    new = Path(path.strip())
    if not new.is_absolute() or ".." in new.parts:
        raise HTTPException(400, "needs a full path")
    (ROOT / "destination.txt").write_text(str(new))
    DEST = new
    # The old archive list says nothing about the new folder.
    with db() as conn:
        conn.execute("DELETE FROM archive")
        conn.execute("DELETE FROM meta WHERE k='indexed_at'")
    reindex_requested.set()
    return {"destination": str(new), "reachable": os.path.isdir(new)}


@app.put("/file")
async def put_file(request: Request, name: str, month: str, sha256: str, mtime: float) -> dict:
    check_user(request)
    if not NAME_RE.match(name) or ".." in name or name.endswith(".part") or not MONTH_RE.match(month):
        raise HTTPException(400, "bad name or month")
    if shutil.disk_usage(HOLDING).free < MIN_FREE_BYTES:
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
