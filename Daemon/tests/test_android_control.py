import io
import socket
import struct
import subprocess
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from devicehubd import android_control as control
from devicehubd.protocol import RpcError


def screencap(width, height, pixel_format=1, pixels=None, colorspace=True):
    header = struct.pack("<III", width, height, pixel_format) + (struct.pack("<I", 1) if colorspace else b"")
    return header + (pixels if pixels is not None else bytes(width * height * 4))


class MessageTests(unittest.TestCase):
    def test_touch_message_matches_scrcpy_inject_touch_event(self):
        message = control.touch_message(control.ACTION_DOWN, 540, 1200, 1080, 2400)
        self.assertEqual(len(message), 32)
        fields = struct.unpack(">BBqiiHHHII", message)
        self.assertEqual(fields, (2, 0, -2, 540, 1200, 1080, 2400, 0xFFFF, 0, 0))
        up = struct.unpack(">BBqiiHHHII", control.touch_message(control.ACTION_UP, 1, 2, 3, 4))
        self.assertEqual((up[1], up[7]), (control.ACTION_UP, 0))

    def test_key_message_matches_scrcpy_inject_keycode(self):
        message = control.key_message(control.KEY_UP, 187)
        self.assertEqual(len(message), 14)
        self.assertEqual(struct.unpack(">BBiii", message), (0, 1, 187, 0, 0))


class ScreencapTests(unittest.TestCase):
    def test_rgba_with_and_without_colorspace_header(self):
        pixels = bytes([10, 20, 30, 255]) * 6
        for colorspace in (True, False):
            with self.subTest(colorspace=colorspace):
                image = control.decode_screencap(screencap(2, 3, 1, pixels, colorspace))
                self.assertEqual(image.size, (2, 3))
                self.assertEqual(image.mode, "RGB")
                self.assertEqual(image.getpixel((1, 2)), (10, 20, 30))

    def test_bgra_is_swapped_to_rgb(self):
        image = control.decode_screencap(screencap(1, 1, 5, bytes([30, 20, 10, 255])))
        self.assertEqual(image.getpixel((0, 0)), (10, 20, 30))

    def test_truncated_unknown_or_oversized_output_is_rejected(self):
        for data in (b"", screencap(2, 2)[:-1], screencap(2, 2, pixel_format=3), struct.pack("<III", 0, 5, 1),
                     struct.pack("<III", 20000, 5, 1)):
            with self.subTest(size=len(data)), self.assertRaises(RpcError) as caught:
                control.decode_screencap(data)
            self.assertEqual(caught.exception.code, "invalidScreenshot")


class DriverTests(unittest.TestCase):
    def run_result(self, returncode=0, stdout=b"", stderr=b""):
        return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)

    def test_screenshot_uses_raw_exec_out_screencap(self):
        with patch.object(control.subprocess, "run", return_value=self.run_result(stdout=screencap(4, 2))) as run:
            image = control.AdbDriver("/adb", "serial").capture()
        self.assertEqual(run.call_args.args[0], ["/adb", "-s", "serial", "exec-out", "screencap"])
        self.assertEqual(image.size, (4, 2))

    def test_screenshot_timeout_is_reported_as_timeout(self):
        with patch.object(control.subprocess, "run", side_effect=subprocess.TimeoutExpired("adb", 20)):
            with self.assertRaises(RpcError) as caught:
                control.AdbDriver("/adb", "serial").capture()
        self.assertEqual(caught.exception.code, "timeout")

    def test_launch_uses_monkey_for_packages_and_am_for_activities(self):
        driver = control.AdbDriver("/adb", "serial")
        with patch.object(control.subprocess, "run", return_value=self.run_result(stdout=b"Events injected: 1")) as run:
            driver.launch("com.android.settings")
            driver.launch("com.example/.Main")
        self.assertEqual(run.call_args_list[0].args[0], ["/adb", "-s", "serial", "shell", "monkey", "-p",
                                                         "com.android.settings", "-c",
                                                         "android.intent.category.LAUNCHER", "1"])
        self.assertEqual(run.call_args_list[1].args[0], ["/adb", "-s", "serial", "shell", "am", "start", "-n",
                                                         "com.example/.Main"])

    def test_launch_failures_are_reported(self):
        driver = control.AdbDriver("/adb", "serial")
        for output in (b"** No activities found to run, monkey aborted.", b"Error: Activity class does not exist"):
            with self.subTest(output=output), \
                    patch.object(control.subprocess, "run", return_value=self.run_result(stdout=output)):
                with self.assertRaises(RpcError):
                    driver.launch("com.example")

    def test_input_channel_starts_once_and_restarts_after_it_ends(self):
        started = []

        class FakeControl:
            def __init__(self, *_):
                self.alive = False
                self.sent = []
                self.closed = False
                started.append(self)

            def start(self):
                self.alive = True

            def send(self, message):
                self.sent.append(message)

            def close(self):
                self.closed = True
                self.alive = False

        driver = control.AdbDriver("/adb", "serial", control_factory=FakeControl)
        with self.assertRaises(RpcError):
            driver.touch(control.ACTION_DOWN, 1, 2, 3, 4)
        driver.start_input()
        driver.start_input()
        self.assertEqual(len(started), 1)
        driver.touch(control.ACTION_DOWN, 1, 2, 3, 4)
        driver.key(control.KEY_DOWN, 3)
        self.assertEqual(len(started[0].sent), 2)
        started[0].alive = False
        driver.start_input()
        self.assertEqual(len(started), 2)
        self.assertTrue(started[0].closed)
        driver.close()
        self.assertTrue(started[1].closed)


class FakeShell:
    """Stands in for `adb shell <script>`: announces the PID line the real script echoes."""

    def __init__(self, args, **_):
        self.args = args
        marker = args[-1].split(":", 1)[0].removeprefix("echo ")
        self.stdout = io.BytesIO(f"{marker}:4242\n".encode())
        self.returncode = None

    def poll(self):
        return self.returncode

    def terminate(self):
        self.returncode = -15

    def kill(self):
        self.returncode = -9

    def wait(self, timeout=None):
        return self.returncode


class ControlChannelTests(unittest.TestCase):
    def setUp(self):
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.port = self.server.getsockname()[1]
        self.received = bytearray()
        self.accepted = threading.Event()
        self.serving = threading.Thread(target=self.serve, daemon=True)
        self.serving.start()
        self.adb_calls = []

    def tearDown(self):
        self.server.close()

    def serve(self):
        try:
            connection, _ = self.server.accept()
        except OSError:
            return  # The test finished without connecting.
        connection.sendall(b"\0")
        self.accepted.set()
        with connection:
            while data := connection.recv(4096):
                self.received.extend(data)

    def adb(self, *args, timeout=8):
        self.adb_calls.append(args)
        if args[0] == "forward" and args[1] == "tcp:0":
            return f"{self.port}\n"
        return ""

    def test_start_send_and_close_own_only_their_server(self):
        channel = control.AndroidControl("/adb", "serial", server=lambda: "/assets/scrcpy-server", popen=FakeShell)
        with patch.object(channel, "_adb", side_effect=self.adb):
            channel.start()
            self.assertTrue(self.accepted.wait(2))
            self.assertTrue(channel.alive)
            self.assertEqual(channel.remote_pid, 4242)
            script = channel.process.args[-1]
            self.assertIn("video=false", script)
            self.assertIn("control=true", script)
            self.assertIn(f"scid={channel.scid}", script)
            channel.send(control.key_message(control.KEY_DOWN, 3))
            marker, remote = channel.marker, channel.remote
            channel.close()
        self.serving.join(2)
        self.assertEqual(bytes(self.received[:14]), control.key_message(control.KEY_DOWN, 3))
        self.assertEqual(self.adb_calls[0], ("push", "/assets/scrcpy-server", remote))
        self.assertEqual(self.adb_calls[1], ("forward", "tcp:0", f"localabstract:scrcpy_{channel.scid}"))
        self.assertIn(("forward", "--remove", f"tcp:{self.port}"), self.adb_calls)
        cleanup = self.adb_calls[-1][1]
        self.assertIn(f"DEVICEHUB_CONTROL_OWNER={marker}", cleanup)
        self.assertIn("kill -9 4242", cleanup)
        self.assertFalse(channel.alive)
        with self.assertRaises(RpcError):
            channel.send(b"x")

    def test_missing_server_asset_reports_input_unavailable(self):
        def missing():
            raise RpcError("androidVideoUnavailable", "scrcpy-server is unavailable")

        channel = control.AndroidControl("/adb", "serial", server=missing, popen=FakeShell)
        with self.assertRaises(RpcError) as caught:
            channel.start()
        self.assertEqual(caught.exception.code, "androidInputUnavailable")


if __name__ == "__main__":
    unittest.main()
