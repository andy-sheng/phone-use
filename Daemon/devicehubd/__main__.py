import argparse
import asyncio
import contextlib
import logging
import os
import signal
import threading
from pathlib import Path
from typing import Optional

from devicehubd.lifetime import exit_after, on_stdin_closed
from devicehubd.supervisor import Supervisor

logger = logging.getLogger("devicehubd")

# Longer than a worker's stop → terminate → kill escalation, so workers can release touch first.
SHUTDOWN_TIMEOUT = 10.0
# Hard limit from the stop request to process exit, even if the event loop is stuck.
EXIT_DEADLINE = 15.0


def _socket_identity(path: Path) -> Optional[tuple[int, int]]:
    try:
        status = path.stat()
    except OSError:
        return None
    return status.st_dev, status.st_ino


def _unlink_if_ours(path: Path, identity: Optional[tuple[int, int]]) -> None:
    # A replacement daemon may already have bound the same path while we were shutting down.
    if identity is not None and _socket_identity(path) == identity:
        with contextlib.suppress(FileNotFoundError):
            path.unlink()


async def serve(socket_path: Path, watch_stdin: bool) -> None:
    supervisor = Supervisor()
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.suppress(FileNotFoundError):
        socket_path.unlink()
    server = await asyncio.start_unix_server(supervisor.serve_client, path=str(socket_path))
    os.chmod(socket_path, 0o600)
    identity = _socket_identity(socket_path)
    logger.info("listening on %s", socket_path)

    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    stop_requested = threading.Lock()

    def request_stop() -> None:
        # May run on the stdin thread; the deadline still fires if the loop never wakes up.
        if not stop_requested.acquire(blocking=False):
            return
        exit_after(EXIT_DEADLINE, before=supervisor.kill_workers)
        with contextlib.suppress(RuntimeError):
            loop.call_soon_threadsafe(stop.set)

    if watch_stdin:
        # Launched by the app: its exit closes our stdin, which is the cue to go.
        on_stdin_closed(request_stop)
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, request_stop)

    monitor = asyncio.create_task(supervisor.monitor())
    await stop.wait()
    monitor.cancel()
    server.close()
    try:
        await asyncio.wait_for(supervisor.shutdown(), SHUTDOWN_TIMEOUT)
    except asyncio.TimeoutError:
        logger.warning("shutdown did not finish within %gs; killing device workers", SHUTDOWN_TIMEOUT)
    supervisor.kill_workers()
    _unlink_if_ours(socket_path, identity)


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
    # Not closing the runner skips asyncio.run teardown, which waits for leftover library tasks
    # and executor threads; none of them may keep the process alive once the app is gone.
    asyncio.Runner().run(serve(args.socket, args.watch_stdin))
    os._exit(0)


if __name__ == "__main__":
    main()
