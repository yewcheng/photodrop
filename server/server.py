"""Receives original photo/video files from the PhotoDrop iPhone app.

Binds to localhost only; `tailscale serve` is the sole way in, and it sets the
Tailscale-User-Login header that authenticates the caller.
"""

import hashlib
import os
import re
import shutil
import uuid
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request

ROOT = Path(os.environ.get("PHOTODROP_ROOT", Path.home() / "PhotoDrop"))
ALLOWED_USER = (ROOT / "allowed_user.txt").read_text().strip()
MIN_FREE_BYTES = 5 * 1024**3
# YYYY/MM/name.ext: the only shape the app sends, so traversal can't get through.
PATH_RE = re.compile(r"^\d{4}/\d{2}/[A-Za-z0-9][A-Za-z0-9._-]{0,200}$")

app = FastAPI()


def check_user(request: Request) -> None:
    if request.headers.get("tailscale-user-login") != ALLOWED_USER:
        raise HTTPException(403, "not allowed")


@app.get("/manifest")
def manifest(request: Request) -> list[str]:
    check_user(request)
    return [
        p.relative_to(ROOT).as_posix()
        for p in ROOT.glob("[0-9][0-9][0-9][0-9]/[0-9][0-9]/*")
        if PATH_RE.match(p.relative_to(ROOT).as_posix()) and not p.name.endswith(".part")
    ]


@app.put("/file")
async def put_file(request: Request, path: str, sha256: str, mtime: float) -> dict:
    check_user(request)
    if not PATH_RE.match(path) or path.endswith(".part"):
        raise HTTPException(400, "bad path")
    final = ROOT / path
    if final.exists():  # never overwrite a verified copy
        return {"status": "exists"}
    if shutil.disk_usage(ROOT).free < MIN_FREE_BYTES:
        raise HTTPException(507, "laptop disk nearly full")

    final.parent.mkdir(parents=True, exist_ok=True)
    part = final.with_name(f"{final.name}.{uuid.uuid4().hex}.part")
    digest = hashlib.sha256()
    try:
        with part.open("wb") as f:
            async for chunk in request.stream():
                f.write(chunk)
                digest.update(chunk)
        if digest.hexdigest() != sha256.lower():
            raise HTTPException(422, "checksum mismatch")
        os.utime(part, (mtime, mtime))
        os.replace(part, final)
    finally:
        part.unlink(missing_ok=True)
    return {"status": "stored"}
