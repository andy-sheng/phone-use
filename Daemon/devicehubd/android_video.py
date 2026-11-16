"""Private scrcpy 3.3.4 H.264 relay, independent of the input channel.

The local wire format is a token line followed by scrcpy's 12-byte codec header
and unchanged (12-byte frame header, Annex-B payload) packets. A stream belongs
to exactly one consumer; reconnecting creates a new server and token.
"""

import asyncio
import contextlib
import hashlib
import hmac
import logging
import os
import secrets
import socket
import struct
from pathlib import Path

from devicehubd.android import android_assets_dir
from devicehubd.protocol import RpcError

logger = logging.getLogger("devicehubd.android.video")
# Must match scripts/android-assets.json (enforced by tests).
SERVER_VERSION = "3.3.4"
SERVER_SHA256 = "8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e"
SERVER_FILENAME = f"scrcpy-server-v{SERVER_VERSION}"
SERVER_MAX_BYTES = 1024 * 1024
START_TIMEOUT = 25
CONSUMER_TIMEOUT = 8
AUTH_TIMEOUT = 3
WRITE_TIMEOUT = 1
FRAME_TIMEOUT = 30
MAX_PACKET_SIZE = 8 * 1024 * 1024
MAX_ADB_OUTPUT = 64 * 1024
SERVER_OPTIONS = (
    "video=true", "video_codec=h264", "audio=false", "control=false",
    "tunnel_forward=true", "send_device_meta=false", "send_dummy_byte=true",
    "send_codec_meta=true", "send_frame_meta=true", "max_size=1920",
    "max_fps=60", "video_bit_rate=8000000", "power_on=false",
    "clipboard_autosync=false", "cleanup=false", "log_level=warn",
)


def server_path() -> Path:
    if override := os.environ.get("DEVICEHUB_SCRCPY_SERVER"):
        path = Path(override).expanduser()
    elif bundled := android_assets_dir():
        path = bundled / SERVER_FILENAME
    else:
        path = Path(__file__).resolve().parents[2] / ".build/android" / SERVER_FILENAME
    try:
        # Bound the read, even if the override points at a large file. The pinned server
        # is far smaller, so a truncated read of a larger file fails the digest check.
        with path.open("rb") as source:
            data = source.read(SERVER_MAX_BYTES)
        if hashlib.sha256(data).hexdigest() != SERVER_SHA256:
            raise ValueError("SHA-256 does not match the pinned official release")
    except (OSError, ValueError) as error:
        raise RpcError("androidVideoUnavailable", f"scrcpy-server {SERVER_VERSION} is unavailable at {path}: {error}") from error
    return path


def validate_metadata(data: bytes) -> tuple[int, int]:
    if len(data) != 12:
        raise RpcError("androidVideoProtocol", "Incomplete scrcpy codec metadata")
    codec, width, height = struct.unpack(">4sII", data)
    if codec != b"h264" or not (0 < width <= 1920 and 0 < height <= 1920):
        raise RpcError("androidVideoProtocol", "Invalid scrcpy H.264 codec or display dimensions")
    return width, height


def packet_size(header: bytes) -> int:
    if len(header) != 12:
        raise RpcError("androidVideoProtocol", "Incomplete scrcpy frame metadata")
    _, size = struct.unpack(">QI", header)
    if not 0 < size <= MAX_PACKET_SIZE:
        raise RpcError("androidVideoProtocol", "scrcpy frame exceeds the relay packet limit")
    return size


class AndroidVideoSession:
    def __init__(self, adb_path: str, serial: str) -> None:
        self.adb_path, self.serial = adb_path, serial
        self.token = secrets.token_urlsafe(32)
        self.scid = f"{secrets.randbelow(0x7fffffff) + 1:08x}"
        self.remote = f"/data/local/tmp/devicehub-scrcpy-{self.scid}-{secrets.token_hex(8)}.jar"
        self.marker = "DEVICEHUB_VIDEO_" + secrets.token_hex(16)
        self.forward_port: int | None = None
        self.remote_pid: int | None = None
        self.process = None
        self.upstream_reader = None
        self.upstream_writer = None
        self.listener = None
        self.consumer = None
        self.metadata = b""
        self.closed = False
        self.claimed = False
        self._auth_count = 0
        self._tasks: set[asyncio.Task] = set()
        self._close_task = None
        self._logs = bytearray()
        self._upload_attempted = False

    def _task(self, coroutine) -> asyncio.Task:
        task = asyncio.create_task(coroutine)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    async def _adb(self, *args: str, timeout: float = 8) -> bytes:
        process = await asyncio.create_subprocess_exec(
            self.adb_path, "-s", self.serial, *args,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            limit=16 * 1024,
        )
        data = bytearray()
        try:
            async with asyncio.timeout(timeout):
                while chunk := await process.stdout.read(4096):
                    data.extend(chunk)
                    if len(data) > MAX_ADB_OUTPUT:
                        raise RpcError("androidVideoFailed", "ADB output exceeds the video command limit")
                await process.wait()
            if process.returncode:
                raise RpcError("androidVideoFailed", data.decode("utf-8", errors="replace")[-2000:] or "ADB video command failed")
            return bytes(data)
        except BaseException:
            if process.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    process.kill()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(process.wait(), 1)
            raise

    async def start(self) -> dict:
        try:
            async with asyncio.timeout(START_TIMEOUT):
                return await self._start()
        except BaseException as error:
            await self.close()
            if isinstance(error, asyncio.CancelledError):
                raise
            if isinstance(error, RpcError):
                raise
            detail = self._logs.decode("utf-8", errors="replace")[-1000:].strip()
            raise RpcError("androidVideoFailed", f"Android video startup failed: {error or type(error).__name__}" +
                           (f" ({detail})" if detail else "")) from error

    async def _start(self) -> dict:
        asset = server_path()
        self._upload_attempted = True
        await self._adb("push", str(asset), self.remote)
        port = (await self._adb("forward", "tcp:0", f"localabstract:scrcpy_{self.scid}")).strip()
        if not port.isdigit() or not 0 < int(port) <= 65535:
            raise RpcError("androidVideoFailed", "ADB did not allocate a video forwarding port")
        self.forward_port = int(port)
        # Every shell value is generated here from fixed ASCII/alphanumeric data.
        # exec keeps the announced PID, while the unique environment marker lets
        # cleanup verify ownership before killing that PID (including PID reuse).
        script = (f"echo {self.marker}:$$; "
                  f"CLASSPATH={self.remote} DEVICEHUB_VIDEO_OWNER={self.marker} "
                  f"exec app_process / com.genymobile.scrcpy.Server {SERVER_VERSION} "
                  f"scid={self.scid} " + " ".join(SERVER_OPTIONS))
        self.process = await asyncio.create_subprocess_exec(
            self.adb_path, "-s", self.serial, "shell", script,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            limit=16 * 1024,
        )
        pid_ready = asyncio.get_running_loop().create_future()
        self._task(self._read_logs(pid_ready))
        await asyncio.wait_for(pid_ready, 3)
        await self._connect()
        self.listener = await asyncio.start_server(self._accept, "127.0.0.1", 0, limit=128, backlog=1)
        self._task(self._expire())
        self._task(self._watch_process())
        return {"port": self.listener.sockets[0].getsockname()[1], "token": self.token}

    async def _read_logs(self, pid_ready) -> None:
        pending = bytearray()
        try:
            while chunk := await self.process.stdout.read(4096):
                self._logs.extend(chunk)
                del self._logs[:-4096]
                if not pid_ready.done():
                    pending.extend(chunk)
                    if len(pending) > 8192:
                        raise RpcError("androidVideoFailed", "scrcpy did not announce its process ID")
                    while b"\n" in pending:
                        line, _, pending = pending.partition(b"\n")
                        prefix = (self.marker + ":").encode()
                        if line.startswith(prefix) and line[len(prefix):].strip().isdigit():
                            pid = int(line[len(prefix):].strip())
                            if pid > 1:
                                self.remote_pid = pid
                                pid_ready.set_result(pid)
                                break
            if not pid_ready.done():
                pid_ready.set_exception(RpcError("androidVideoFailed", "scrcpy exited before announcing its process ID"))
        except Exception as error:
            if not pid_ready.done():
                pid_ready.set_exception(error)

    async def _connect(self) -> None:
        deadline = asyncio.get_running_loop().time() + 10
        while asyncio.get_running_loop().time() < deadline:
            if self.process.returncode is not None:
                raise RpcError("androidVideoFailed", "scrcpy server exited: " + self._logs.decode("utf-8", errors="replace")[-1000:])
            writer = None
            try:
                async with asyncio.timeout(.5):
                    reader, writer = await asyncio.open_connection("127.0.0.1", self.forward_port, limit=64 * 1024)
                    dummy = await reader.readexactly(1)
            except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError):
                if writer is not None:
                    writer.close()
                await asyncio.sleep(.05)
                continue
            self.upstream_reader, self.upstream_writer = reader, writer
            if dummy != b"\0":
                raise RpcError("androidVideoProtocol", "Invalid scrcpy connection acknowledgement")
            self.metadata = await asyncio.wait_for(reader.readexactly(12), 5)
            validate_metadata(self.metadata)
            return
        raise RpcError("androidVideoFailed", "Timed out connecting to the scrcpy video socket")

    def _accept(self, reader, writer) -> None:
        if self.closed or self.claimed or self._auth_count >= 2:
            writer.close()
            return
        self._auth_count += 1
        self._task(self._serve(reader, writer))

    async def _serve(self, reader, writer) -> None:
        owns_stream = False
        reading = forwarding = None
        try:
            line = await asyncio.wait_for(reader.readline(), AUTH_TIMEOUT)
            if self.closed or self.claimed or not hmac.compare_digest(line, (self.token + "\n").encode()):
                return
            self.claimed = owns_stream = True
            self.consumer = writer
            self.listener.close()
            writer.transport.set_write_buffer_limits(high=64 * 1024, low=16 * 1024)
            sock = writer.get_extra_info("socket")
            if sock is not None:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 64 * 1024)
            writer.write(self.metadata)
            await asyncio.wait_for(writer.drain(), WRITE_TIMEOUT)
            # Detect a consumer disappearing even while the device sends no frame.
            reading = asyncio.create_task(reader.read(1))
            forwarding = asyncio.create_task(self._forward(writer))
            done, _ = await asyncio.wait((reading, forwarding), return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except (Exception, asyncio.CancelledError) as error:
            if not isinstance(error, asyncio.CancelledError):
                logger.info("Android video relay ended: %s", error or type(error).__name__)
        finally:
            self._auth_count -= 1
            children = [task for task in (reading, forwarding) if task is not None]
            for task in children:
                task.cancel()
            await asyncio.gather(*children, return_exceptions=True)
            writer.close()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(writer.wait_closed(), .2)
            if owns_stream:
                self._request_close()

    async def _forward(self, writer) -> None:
        # Do not drop interdependent H.264 packets. Bound each packet and abort a
        # slow consumer instead of queuing seconds of increasingly stale frames.
        while not self.closed:
            # A static display may produce no packets indefinitely. The consumer
            # EOF and process watcher detect disconnects; only an announced,
            # incomplete payload needs a timeout.
            header = await self.upstream_reader.readexactly(12)
            size = packet_size(header)
            payload = await asyncio.wait_for(self.upstream_reader.readexactly(size), FRAME_TIMEOUT)
            if not payload.startswith((b"\0\0\0\1", b"\0\0\1")):
                raise RpcError("androidVideoProtocol", "Expected an Annex-B H.264 packet")
            writer.write(header)
            writer.write(payload)
            await asyncio.wait_for(writer.drain(), WRITE_TIMEOUT)

    async def _expire(self) -> None:
        await asyncio.sleep(CONSUMER_TIMEOUT)
        if not self.claimed:
            self._request_close()

    async def _watch_process(self) -> None:
        await self.process.wait()
        self._request_close()

    def _request_close(self) -> None:
        if self._close_task is None:
            self.closed = True
            self._close_task = asyncio.create_task(self._cleanup())

    async def close(self) -> None:
        self._request_close()
        await asyncio.shield(self._close_task)

    async def _cleanup(self) -> None:
        if self.listener is not None:
            self.listener.close()
            await self.listener.wait_closed()
        for writer in (self.consumer, self.upstream_writer):
            if writer is not None:
                writer.close()
        tasks = list(self._tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        cleanup = []
        if self.forward_port is not None:
            cleanup.append(self._adb("forward", "--remove", f"tcp:{self.forward_port}", timeout=1.5))
        # Kill only the PID announced by our shell and still carrying our private
        # marker. No process-name matching, global forward removal, or pkill.
        if self.remote_pid is not None:
            script = (f"case \"$(tr '\\000' '\\n' < /proc/{self.remote_pid}/environ 2>/dev/null)\" in "
                      f"*DEVICEHUB_VIDEO_OWNER={self.marker}*) kill -9 {self.remote_pid};; esac; "
                      f"rm -f {self.remote}")
            cleanup.append(self._adb("shell", script, timeout=1.5))
        elif self._upload_attempted:
            cleanup.append(self._adb("shell", "rm", "-f", self.remote, timeout=1.5))
        results = await asyncio.gather(*cleanup, return_exceptions=True)
        for result in results:
            if isinstance(result, Exception):
                logger.debug("Android video cleanup: %s", result)
        if self.process is not None and self.process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), .5)
            except asyncio.TimeoutError:
                with contextlib.suppress(ProcessLookupError):
                    self.process.kill()
                with contextlib.suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(self.process.wait(), .5)


class AndroidVideoManager:
    def __init__(self, adb_path: str, serial: str, *, session_factory=AndroidVideoSession) -> None:
        self.adb_path, self.serial, self._factory = adb_path, serial, session_factory
        self.session = None
        self._lock = asyncio.Lock()
        self.closed = False

    async def start(self) -> dict:
        async with self._lock:
            if self.closed:
                raise RpcError("disconnected", "The Android video manager is closing")
            if self.session is not None:
                await self.session.close()
            session = self._factory(self.adb_path, self.serial)
            self.session = session
            return await session.start()

    async def stop(self, token: str) -> dict:
        if not isinstance(token, str) or not token:
            raise RpcError("invalidParams", "Missing Android video token")
        async with self._lock:
            if self.session is not None and hmac.compare_digest(token, self.session.token):
                await self.session.close()
                self.session = None
        return {}

    async def close(self) -> None:
        self.closed = True
        async with self._lock:
            if self.session is not None:
                await self.session.close()
                self.session = None
