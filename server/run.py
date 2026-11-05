"""Runs the receiver on both listeners in one process, so there is one mover and one pairing code.

localhost:8860 for tailscale serve and the pairing page; LAN_PORT over HTTPS for phones paired by QR code.
"""

import asyncio

import uvicorn

import server


async def main() -> None:
    server.ROOT.mkdir(parents=True, exist_ok=True)
    server.ensure_cert()
    local = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=8860))
    lan = uvicorn.Server(uvicorn.Config(
        server.app, host="0.0.0.0", port=server.LAN_PORT, lifespan="off",
        ssl_certfile=str(server.CERT), ssl_keyfile=str(server.CERT_KEY),
    ))
    await asyncio.gather(local.serve(), lan.serve())


if __name__ == "__main__":
    asyncio.run(main())
