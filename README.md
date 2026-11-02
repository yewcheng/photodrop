# PhotoDrop

Copies original photos, videos and Live Photos (HEIC + MOV) from an iPhone to a
laptop over Tailscale. Files are byte-for-byte originals, checked with SHA-256.

- `Sources/`: the iPhone app. Built by GitHub Actions, installed with SideStore
  from `https://raw.githubusercontent.com/yewcheng/photodrop/main/source.json`.
- `server/`: the laptop receiver. It listens on localhost and is exposed with
  `tailscale serve --bg --https=5443 8860`. It only accepts the Tailscale login
  in `~/PhotoDrop/allowed_user.txt`.

Test the receiver: `python server/test_server.py`
