import argparse
import asyncio
import contextlib
import logging
import os
import signal
import sys
from pathlib import Path

from devicehubd.supervisor import Supervisor

logger = logging.getLogger("devicehubd")


async def serve(socket_path: Path, watch_stdin: bool) -> None:
    supervisor = Supervisor()
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.suppress(FileNotFoundError):
        socket_path.unlink()
    server = await asyncio.start_unix_server(supervisor.serve_client, path=str(socket_path))
    os.chmod(socket_path, 0o600)
    logger.info("listening on %s", socket_path)

    stop = asyncio.Event()
    if watch_stdin:
        # Launched by the app: its exit closes our stdin, which is the cue to go.
        loop = asyncio.get_running_loop()
        reader = asyncio.StreamReader()
        await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)

        async def watch() -> None:
            while await reader.read(4096):
                pass
            stop.set()

        asyncio.create_task(watch())
    for signum in (signal.SIGINT, signal.SIGTERM):
        asyncio.get_running_loop().add_signal_handler(signum, stop.set)

    monitor = asyncio.create_task(supervisor.monitor())
    await stop.wait()
    monitor.cancel()
    server.close()
    await supervisor.shutdown()
    with contextlib.suppress(FileNotFoundError):
        socket_path.unlink()


def default_socket() -> Path:
    return Path.home() / "Library" / "Application Support" / "DeviceHub" / "devicehubd.sock"


def main() -> None:
    parser = argparse.ArgumentParser(prog="devicehubd")
    parser.add_argument("--socket", type=Path, default=default_socket())
    parser.add_argument("--watch-stdin", action="store_true", help="exit when stdin closes")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="[devicehubd] %(levelname)s %(name)s: %(message)s",
    )
    logging.getLogger("pymobiledevice3").setLevel(logging.WARNING)
    asyncio.run(serve(args.socket, args.watch_stdin))
    # Leftover library tasks must not keep the process alive once the app is gone.
    os._exit(0)


if __name__ == "__main__":
    main()
