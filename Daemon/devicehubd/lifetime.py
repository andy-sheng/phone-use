"""Process lifetime guards shared by the daemon and its device workers.

Graceful shutdown awaits library code (tunnels, Bonjour, ADB calls) that can hang, and
`asyncio.run` teardown additionally waits for cancelled tasks and executor threads. These guards
run on plain threads, so they still act when the event loop itself is stuck.
"""

import os
import sys
import threading
from typing import Callable, Optional

# From a worker's shutdown to its exit. Longer than the supervisor's own stop → terminate → kill
# escalation, so it only decides when the supervisor is gone and nobody else will reap the worker.
WORKER_EXIT_DEADLINE = 10.0


def exit_after(seconds: float, code: int = 0, before: Optional[Callable[[], None]] = None) -> None:
    """Ends the process after `seconds` unless it has already exited."""

    def expire() -> None:
        sys.stderr.write(f"[devicehubd] shutdown did not finish within {seconds:g}s; exiting\n")
        if before is not None:
            try:
                before()
            except Exception:
                pass
        os._exit(code)

    timer = threading.Timer(seconds, expire)
    timer.daemon = True
    timer.start()


def on_stdin_closed(callback: Callable[[], None]) -> None:
    """Calls `callback` on a background thread once the parent closes our stdin."""

    def watch() -> None:
        try:
            while os.read(sys.stdin.fileno(), 4096):
                pass
        except OSError:
            pass
        callback()

    threading.Thread(target=watch, name="stdin-watch", daemon=True).start()
