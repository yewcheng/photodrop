"""Self-check: python server/test_server.py"""

import hashlib
import json
import os
import shutil
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


def put(name, body, month="202603", sha=None, mtime=1000000000):
    q = urllib.parse.urlencode(
        {"name": name, "month": month, "sha256": sha or hashlib.sha256(body).hexdigest(), "mtime": mtime}
    )
    return call("PUT", f"/file?{q}", body)


def wait_for(check, what):
    for _ in range(100):
        if check():
            return
        time.sleep(0.1)
    raise AssertionError(f"timed out: {what}")


def held(root):
    return [p for p in (root / "holding").rglob("*") if p.is_file()]


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp) / "laptop"
    dest = Path(tmp) / "desktop"
    root.mkdir()
    (root / "allowed_user.txt").write_text(USER)
    (root / "destination.txt").write_text(str(dest))
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "server:app", "--port", str(PORT), "--log-level", "warning"],
        cwd=Path(__file__).parent,
        env={**os.environ, "PHOTODROP_ROOT": str(root), "PHOTODROP_MOVE_INTERVAL": "0.2"},
    )
    try:
        for _ in range(50):
            try:
                call("GET", "/manifest")
                break
            except urllib.error.URLError:
                time.sleep(0.2)

        assert call("GET", "/manifest", user=None)[0] == 403
        assert call("GET", "/manifest", user="other@example.com")[0] == 403

        # Desktop offline: the file waits on the laptop.
        data = os.urandom(3_000_000)
        key = f"img_1.heic|{len(data)}"
        status, reply = put("IMG_1.HEIC", data)
        assert status == 200 and reply["state"] == "holding"
        time.sleep(0.6)
        m = call("GET", "/manifest")[1]
        assert m["holding"] == [key] and not m["desktop_online"] and m["verified"] == []
        assert len(held(root)) == 1 and held(root)[0].read_bytes() == data

        # A bad checksum leaves nothing behind.
        assert put("IMG_2.HEIC", b"x", sha="0" * 64)[0] == 422
        assert len(held(root)) == 1

        # Sending it again doesn't make a second copy.
        assert put("IMG_1.HEIC", data)[1]["state"] == "holding"
        assert len(held(root)) == 1

        # Desktop back: copied into the existing year folder, then the laptop copy goes.
        (dest / "F. 2026").mkdir(parents=True)
        wait_for(lambda: not held(root), "holding copy removed")
        final = dest / "F. 2026/202603_a/IMG_1.HEIC"
        assert final.read_bytes() == data and final.stat().st_mtime == 1000000000
        assert call("GET", "/manifest")[1]["verified"] == [key]

        # Same name, different contents: both kept, the archive copy untouched.
        other = os.urandom(1000)
        assert put("IMG_1.HEIC", other)[1]["state"] == "holding"
        wait_for(lambda: not held(root), "second file moved")
        assert final.read_bytes() == data
        assert len(list(final.parent.iterdir())) == 2

        # A copy that can't be written stays on the laptop.
        blocker = dest / "F. 2026/202604_a"
        blocker.write_text("a file where the month folder should be")
        third = os.urandom(500)
        assert put("IMG_3.HEIC", third, month="202604")[1]["state"] == "holding"
        time.sleep(0.6)
        assert len(held(root)) == 1 and held(root)[0].read_bytes() == third
        assert call("GET", "/manifest")[1]["move_error"]
        blocker.unlink()
        wait_for(lambda: not held(root), "moved after the problem cleared")

        # Bad destination names never reach the disk.
        for bad in ("../evil.txt", "a/b.txt", "a\\b.txt", "C:evil.txt", "x.part", ".hidden", "con.txt", "trail."):
            assert put(bad, b"x")[0] == 400, bad
        assert put("ok.txt", b"x", month="../..")[0] == 400
        assert put("ok.txt", b"x", month="202613")[0] == 400
        print("ok")
    finally:
        proc.terminate()
        proc.wait()
        time.sleep(0.5)
    shutil.rmtree(tmp, ignore_errors=True)
