import asyncio
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from devicehubd.__main__ import _socket_identity, _unlink_if_ours
from devicehubd.supervisor import Supervisor

DAEMON_DIR = Path(__file__).resolve().parents[1]

# Runs the real daemon entry point with device discovery replaced, so no device is touched.
HARNESS = """
import asyncio, sys, threading, time
import devicehubd.__main__ as entry
from devicehubd.supervisor import Supervisor

mode = sys.argv.pop(1)

async def idle(self):
    await asyncio.sleep(3600)

async def stubborn():
    while True:
        try:
            await asyncio.sleep(3600)
        except asyncio.CancelledError:
            pass

async def leave_library_work(self):
    # What asyncio.run teardown used to wait on: a task that swallows cancellation and a
    # blocked executor thread.
    asyncio.create_task(stubborn())
    asyncio.get_running_loop().run_in_executor(None, time.sleep, 3600)
    await asyncio.sleep(3600)

async def block_loop(self):
    await asyncio.sleep(0.1)
    time.sleep(3600)

async def hang(self):
    await asyncio.sleep(3600)

Supervisor.monitor = idle
if mode == "leftover-work":
    Supervisor.monitor = leave_library_work
elif mode == "hung-shutdown":
    entry.SHUTDOWN_TIMEOUT = 0.5
    Supervisor.shutdown = hang
elif mode == "blocked-loop":
    entry.EXIT_DEADLINE = 1.0
    Supervisor.monitor = block_loop
entry.main()
"""


def short_tempdir() -> str:
    directory = tempfile.mkdtemp(prefix="dh")
    if len(directory) > 80:  # AF_UNIX paths are limited to 104 bytes on macOS.
        os.rmdir(directory)
        directory = tempfile.mkdtemp(prefix="dh", dir="/tmp")
    return directory


class DaemonExitTests(unittest.TestCase):
    def launch(self, mode: str) -> tuple[subprocess.Popen, Path]:
        directory = short_tempdir()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", directory]))
        path = Path(directory) / "d.sock"
        environment = dict(os.environ, PYTHONPATH=str(DAEMON_DIR))
        process = subprocess.Popen(
            [sys.executable, "-c", HARNESS, mode, "--socket", str(path), "--watch-stdin"],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment,
        )
        self.addCleanup(lambda: process.poll() is None and process.kill())
        deadline = time.monotonic() + 20
        while not path.exists():
            self.assertIsNone(process.poll(), "daemon exited before listening")
            self.assertLess(time.monotonic(), deadline, "daemon did not start listening")
            time.sleep(0.05)
        time.sleep(0.3)
        return process, path

    def assert_exits_when_app_closes_stdin(self, mode: str, within: float) -> Path:
        process, path = self.launch(mode)
        started = time.monotonic()
        process.stdin.close()
        try:
            process.wait(within)
        except subprocess.TimeoutExpired:
            self.fail(f"daemon still running {within}s after its stdin closed ({mode})")
        self.assertEqual(process.returncode, 0)
        self.assertLess(time.monotonic() - started, within)
        return path

    def test_idle_daemon_exits_and_removes_its_socket(self):
        path = self.assert_exits_when_app_closes_stdin("idle", within=3)
        self.assertFalse(path.exists())

    def test_leftover_library_work_does_not_delay_exit(self):
        self.assert_exits_when_app_closes_stdin("leftover-work", within=3)

    def test_hung_shutdown_is_bounded(self):
        self.assert_exits_when_app_closes_stdin("hung-shutdown", within=4)

    def test_blocked_event_loop_still_exits_after_deadline(self):
        self.assert_exits_when_app_closes_stdin("blocked-loop", within=4)


class SocketOwnershipTests(unittest.TestCase):
    def bind(self, path: Path) -> socket.socket:
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        self.addCleanup(listener.close)
        return listener

    def test_exiting_daemon_keeps_a_replacement_daemons_socket(self):
        directory = short_tempdir()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", directory]))
        path = Path(directory) / "d.sock"
        self.bind(path)
        ours = _socket_identity(path)
        path.unlink()
        self.bind(path)  # A newer daemon took over the path.

        _unlink_if_ours(path, ours)
        self.assertTrue(path.exists())

        _unlink_if_ours(path, _socket_identity(path))
        self.assertFalse(path.exists())


class SupervisorShutdownTests(unittest.IsolatedAsyncioTestCase):
    async def test_workers_start_stopping_before_slow_pairing_teardown(self):
        supervisor = Supervisor()
        events = []

        class Worker:
            def stop(self):
                events.append("worker stop")

            async def wait_closed(self):
                events.append("worker closed")

        async def slow_pairing(owner):
            events.append("pairing closing")
            await asyncio.sleep(0.05)
            events.append("pairing closed")

        supervisor.workers = {"udid": Worker()}
        supervisor._wireless_owner = object()
        with patch.object(supervisor, "stop_wireless_pairing", slow_pairing):
            await supervisor.shutdown()
        self.assertEqual(events, ["worker stop", "pairing closing", "pairing closed", "worker closed"])

    def test_kill_workers_leaves_no_worker_running(self):
        supervisor = Supervisor()
        running = subprocess.Popen(["/bin/sleep", "60"])
        self.addCleanup(lambda: running.poll() is None and running.kill())
        supervisor.workers = {"udid": SimpleNamespace(process=SimpleNamespace(pid=running.pid, returncode=None))}

        supervisor.kill_workers()
        self.assertEqual(running.wait(5), -9)


if __name__ == "__main__":
    unittest.main()
