# PhotoDrop

Copies original photos, videos and Live Photos (HEIC + MOV) from an iPhone to a
home desktop over Tailscale, in two stages:

1. iPhone -> holding folder on the laptop, checked with SHA-256.
2. Laptop -> desktop share, read back and checked again. Only then is the
   holding copy deleted. The app never deletes anything from the phone.

- `Sources/`: the iPhone app. Built by GitHub Actions, installed with SideStore
  from `https://raw.githubusercontent.com/yewcheng/photodrop/main/source.json`.
- `server/`: the laptop receiver. It listens on localhost and is exposed with
  `tailscale serve --bg --https=5443 8860`.

Local settings live in `~/PhotoDrop`, outside this repo: `allowed_user.txt` (the
Tailscale login allowed in) and `destination.txt` (the archive folder).

Test the receiver: `python server/test_server.py`
