"""Android input and capture without MaaFramework.

Touch and key events go through a private scrcpy 3.3.4 server started with ``video=false``
and ``control=true``: one long-lived control socket per worker, separate from the video relay.
Without video the server injects positional events at raw display coordinates of display 0,
so callers pass native screenshot pixels. Injection is asynchronous and unacknowledged; the
worker checks input permission and display geometry itself before sending.

Screenshots use ``adb exec-out screencap`` (raw pixels, no on-device PNG encoding); app
launches use ``am``/``monkey`` and need no input permission.
"""

import contextlib
import logging
import secrets
import socket
import struct
import subprocess
import threading
import time
from typing import Callable

from devicehubd.android_video import SERVER_VERSION, server_path
from devicehubd.protocol import RpcError

logger = logging.getLogger("devicehubd.android.control")

CONTROL_OPTIONS = (
    "video=false", "audio=false", "control=true", "tunnel_forward=true",
    "send_device_meta=false", "send_dummy_byte=true", "power_on=false",
    "clipboard_autosync=false", "cleanup=false", "log_level=warn",
)
START_TIMEOUT = 15
SEND_TIMEOUT = 2
ADB_TIMEOUT = 8
SCREENSHOT_TIMEOUT = 20
LAUNCH_TIMEOUT = 15

# scrcpy ControlMessage types and android.view constants.
TYPE_INJECT_KEYCODE = 0
TYPE_INJECT_TOUCH_EVENT = 2
ACTION_DOWN, ACTION_UP, ACTION_MOVE = 0, 1, 2
KEY_DOWN, KEY_UP = 0, 1
# scrcpy's POINTER_ID_GENERIC_FINGER: a finger with no mouse semantics.
POINTER_ID = -2

# screencap pixel formats (android.graphics.PixelFormat) and their PIL raw modes.
PIXEL_FORMATS = {1: "RGBA", 2: "RGBX", 5: "BGRA"}


def touch_message(action: int, x: int, y: int, width: int, height: int) -> bytes:
    """INJECT_TOUCH_EVENT: type, action, pointer id, position (x, y, screen size), pressure, buttons."""
    pressure = 0 if action == ACTION_UP else 0xFFFF
    return struct.pack(">BBqiiHHHII", TYPE_INJECT_TOUCH_EVENT, action, POINTER_ID,
                       x, y, width & 0xFFFF, height & 0xFFFF, pressure, 0, 0)


def key_message(action: int, keycode: int, meta_state: int = 0) -> bytes:
    """INJECT_KEYCODE: type, action, keycode, repeat, meta state."""
    return struct.pack(">BBiii", TYPE_INJECT_KEYCODE, action, keycode, 0, meta_state)


def decode_screencap(data: bytes):
    """Decodes raw ``screencap`` output into an RGB PIL image.

    The header is width, height and format (little-endian u32), followed on Android 9+ by a
    color space word; the header size is whatever precedes width * height * 4 pixel bytes.
    """
    from PIL import Image

    if len(data) < 12:
        raise RpcError("invalidScreenshot", "Android screencap returned no image")
    width, height, pixel_format = struct.unpack_from("<III", data)
    if not (0 < width <= 16384 and 0 < height <= 16384):
        raise RpcError("invalidScreenshot", "Android screencap reported invalid dimensions")
    mode = PIXEL_FORMATS.get(pixel_format)
    if mode is None:
        raise RpcError("invalidScreenshot", f"Unsupported Android screencap pixel format {pixel_format}")
    size = width * height * 4
    header = len(data) - size
    if header not in (12, 16):
        raise RpcError("invalidScreenshot", "Android screencap size does not match its dimensions")
    pixels = memoryview(data)[header:]
    return Image.frombuffer("RGBA", (width, height), pixels, "raw", mode, 0, 1).convert("RGB")


class AndroidControl:
    """One private control-only scrcpy server and its socket."""

    def __init__(self, adb_path: str, serial: str, *, server=server_path,
                 popen: Callable = subprocess.Popen) -> None:
        self.adb_path, self.serial = adb_path, serial
        self._server, self._popen = server, popen
        self.scid = f"{secrets.randbelow(0x7fffffff) + 1:08x}"
        self.remote = f"/data/local/tmp/devicehub-control-{self.scid}-{secrets.token_hex(8)}.jar"
        self.marker = "DEVICEHUB_CONTROL_" + secrets.token_hex(16)
        self.forward_port: int | None = None
        self.remote_pid: int | None = None
        self.process = None
        self.sock: socket.socket | None = None
        self._lock = threading.Lock()
        self._logs = bytearray()
        self._pid_ready = threading.Event()
        self._uploaded = False
        self.closed = False

    @property
    def alive(self) -> bool:
        return self.sock is not None and not self.closed and (self.process is None or self.process.poll() is None)

    def _adb(self, *args: str, timeout: float = ADB_TIMEOUT) -> str:
        try:
            result = subprocess.run([self.adb_path, "-s", self.serial, *args], capture_output=True,
                                    timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RpcError("androidInputUnavailable", f"ADB failed while preparing Android input: {error}") from error
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        if result.returncode:
            raise RpcError("androidInputUnavailable", output[-2000:].strip() or "ADB failed while preparing Android input")
        return output

    def start(self) -> None:
        try:
            asset = self._server()
        except RpcError as error:
            raise RpcError("androidInputUnavailable", error.message) from error
        deadline = time.monotonic() + START_TIMEOUT
        try:
            self._uploaded = True
            self._adb("push", str(asset), self.remote)
            port = self._adb("forward", "tcp:0", f"localabstract:scrcpy_{self.scid}").strip()
            if not port.isdigit() or not 0 < int(port) <= 65535:
                raise RpcError("androidInputUnavailable", "ADB did not allocate an input forwarding port")
            self.forward_port = int(port)
            # Every shell value is generated here from fixed ASCII/alphanumeric data. exec keeps the
            # announced PID; the private environment marker lets cleanup verify ownership first.
            script = (f"echo {self.marker}:$$; "
                      f"CLASSPATH={self.remote} DEVICEHUB_CONTROL_OWNER={self.marker} "
                      f"exec app_process / com.genymobile.scrcpy.Server {SERVER_VERSION} "
                      f"scid={self.scid} " + " ".join(CONTROL_OPTIONS))
            self.process = self._popen([self.adb_path, "-s", self.serial, "shell", script],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            threading.Thread(target=self._read_logs, name="android-control-logs", daemon=True).start()
            if not self._pid_ready.wait(max(0.1, min(3, deadline - time.monotonic()))):
                raise RpcError("androidInputUnavailable", "scrcpy did not announce its process ID" + self._log_tail())
            self._connect(deadline)
        except BaseException:
            self.close()
            raise
        threading.Thread(target=self._drain, name="android-control-drain", daemon=True).start()

    def _log_tail(self) -> str:
        detail = self._logs.decode("utf-8", errors="replace")[-1000:].strip()
        return f" ({detail})" if detail else ""

    def _read_logs(self) -> None:
        prefix = (self.marker + ":").encode()
        with contextlib.suppress(Exception):
            for line in self.process.stdout:
                if not self._pid_ready.is_set() and line.startswith(prefix):
                    value = line[len(prefix):].strip()
                    if value.isdigit() and int(value) > 1:
                        self.remote_pid = int(value)
                        self._pid_ready.set()
                        continue
                self._logs.extend(line)
                del self._logs[:-4096]

    def _connect(self, deadline: float) -> None:
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RpcError("androidInputUnavailable", "scrcpy input server exited" + self._log_tail())
            sock = None
            try:
                sock = socket.create_connection(("127.0.0.1", self.forward_port), timeout=0.5)
                dummy = sock.recv(1)
            except OSError:
                if sock is not None:
                    sock.close()
                time.sleep(0.05)
                continue
            if dummy != b"\0":
                # adb accepts the forward before the device listens and then closes it.
                sock.close()
                time.sleep(0.05)
                continue
            sock.settimeout(SEND_TIMEOUT)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.sock = sock
            return
        raise RpcError("androidInputUnavailable", "Timed out connecting to the scrcpy input socket" + self._log_tail())

    def _drain(self) -> None:
        # The server may send device messages (clipboard, UHID output); none are used. EOF means
        # the server is gone; the next send fails and the worker starts a new channel.
        sock = self.sock
        with contextlib.suppress(Exception):
            sock.settimeout(None)
            while sock.recv(4096):
                pass
        self.closed = True

    def send(self, message: bytes) -> None:
        with self._lock:
            if not self.alive:
                raise RpcError("androidInputUnavailable", "The Android input channel is closed")
            try:
                self.sock.sendall(message)
            except OSError as error:
                self.closed = True
                raise RpcError("androidInputUnavailable", f"The Android input channel failed: {error}") from error

    def close(self) -> None:
        self.closed = True
        sock, self.sock = self.sock, None
        if sock is not None:
            with contextlib.suppress(OSError):
                sock.shutdown(socket.SHUT_RDWR)
            sock.close()
        if self.forward_port is not None:
            with contextlib.suppress(RpcError):
                self._adb("forward", "--remove", f"tcp:{self.forward_port}", timeout=1.5)
            self.forward_port = None
        # Kill only the PID our shell announced that still carries our private marker.
        if self.remote_pid is not None:
            script = (f"case \"$(tr '\\000' '\\n' < /proc/{self.remote_pid}/environ 2>/dev/null)\" in "
                      f"*DEVICEHUB_CONTROL_OWNER={self.marker}*) kill -9 {self.remote_pid};; esac; "
                      f"rm -f {self.remote}")
            with contextlib.suppress(RpcError):
                self._adb("shell", script, timeout=1.5)
            self.remote_pid = None
        elif self._uploaded:
            with contextlib.suppress(RpcError):
                self._adb("shell", "rm", "-f", self.remote, timeout=1.5)
        self._uploaded = False
        process, self.process = self.process, None
        if process is not None and process.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                process.terminate()
            try:
                process.wait(0.5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    process.kill()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(0.5)


class AdbDriver:
    """The worker's device access: raw screenshots, app launches and the scrcpy input channel."""

    def __init__(self, adb_path: str, serial: str, *, control_factory=AndroidControl) -> None:
        self.adb_path, self.serial = adb_path, serial
        self._control_factory = control_factory
        self._control: AndroidControl | None = None
        self._lock = threading.Lock()

    def capture(self, physical_id: str | None = None):
        command = [self.adb_path, "-s", self.serial, "exec-out", "screencap"]
        if physical_id is not None:
            command.extend(["-d", physical_id])
        try:
            result = subprocess.run(command,
                                    capture_output=True, timeout=SCREENSHOT_TIMEOUT, check=False)
        except subprocess.TimeoutExpired as error:
            raise RpcError("timeout", "Android screenshot timed out; reopen the device before retrying") from error
        except OSError as error:
            raise RpcError("androidCommandFailed", f"Android screenshot failed: {error}") from error
        if result.returncode:
            detail = result.stderr.decode("utf-8", errors="replace")[-2000:].strip()
            raise RpcError("androidCommandFailed", f"Android screenshot failed: {detail or 'ADB error'}")
        return decode_screencap(result.stdout)

    def launch(self, component: str) -> None:
        if "/" in component:
            command = ["am", "start", "-n", component]
        else:
            command = ["monkey", "-p", component, "-c", "android.intent.category.LAUNCHER", "1"]
        try:
            result = subprocess.run([self.adb_path, "-s", self.serial, "shell", *command], capture_output=True,
                                    timeout=LAUNCH_TIMEOUT, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RpcError("androidCommandFailed", f"Android launch failed: {error}") from error
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        if result.returncode or "Error" in output or "monkey aborted" in output:
            raise RpcError("androidCommandFailed", f"Android launch failed: {output[-1000:].strip() or 'ADB error'}")

    def start_input(self) -> None:
        """Starts the input channel unless one is running; restarts a channel that ended."""
        with self._lock:
            if self._control is not None and self._control.alive:
                return
            if self._control is not None:
                self._control.close()
                self._control = None
            control = self._control_factory(self.adb_path, self.serial)
            control.start()
            self._control = control

    def _send(self, message: bytes) -> None:
        control = self._control
        if control is None:
            raise RpcError("androidInputUnavailable", "The Android input channel is not running")
        control.send(message)

    def touch(self, action: int, x: int, y: int, width: int, height: int) -> None:
        self._send(touch_message(action, x, y, width, height))

    def key(self, action: int, keycode: int, meta_state: int = 0) -> None:
        self._send(key_message(action, keycode, meta_state))

    def close(self) -> None:
        with self._lock:
            if self._control is not None:
                self._control.close()
                self._control = None
