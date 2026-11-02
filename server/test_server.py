"""Self-check: python server/test_server.py"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

PORT = 8861
BASE = f"http://127.0.0.1:{PORT}"
USER = "me@example.com"


def call(method, route, body=None, user=USER):
    req = urllib.request.Request(BASE + route, data=body, method=method)
    if user:
        req.add_header("Tailscale-User-Login", user)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, None


def put(path, body, sha=None, mtime=1000000000):
    q = urllib.parse.urlencode(
        {"path": path, "sha256": sha or hashlib.sha256(body).hexdigest(), "mtime": mtime}
    )
    return call("PUT", f"/file?{q}", body)


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "allowed_user.txt").write_text(USER)
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "server:app", "--port", str(PORT), "--log-level", "warning"],
        cwd=Path(__file__).parent,
        env={**os.environ, "PHOTODROP_ROOT": tmp},
    )
    try:
        for _ in range(50):
            try:
                call("GET", "/manifest")
                break
            except urllib.error.URLError:
                time.sleep(0.2)

        data = os.urandom(3_000_000)
        assert call("GET", "/manifest", user=None)[0] == 403
        assert call("GET", "/manifest", user="other@example.com")[0] == 403
        assert put("2025/03/a_IMG_1.HEIC", data)[0] == 200
        stored = root / "2025/03/a_IMG_1.HEIC"
        assert stored.read_bytes() == data
        assert stored.stat().st_mtime == 1000000000

        # A bad checksum leaves nothing behind, so the file is retried.
        assert put("2025/03/b.MOV", b"x", sha="0" * 64)[0] == 422
        assert not list((root / "2025/03").glob("b.MOV*"))
        assert call("GET", "/manifest")[1] == ["2025/03/a_IMG_1.HEIC"]

        # An existing verified file is never replaced.
        assert put("2025/03/a_IMG_1.HEIC", b"different")[1] == {"status": "exists"}
        assert stored.read_bytes() == data

        for bad in ("../evil.txt", "2025/03/../../evil.txt", "2025/03/..", "C:/evil.txt", "x.part", "2025/03/a.part"):
            assert put(bad, b"x")[0] == 400, bad
        assert not (root.parent / "evil.txt").exists()
        print("ok")
    finally:
        proc.terminate()
        proc.wait()
