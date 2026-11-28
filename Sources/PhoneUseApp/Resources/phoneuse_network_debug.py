"""Per-launch, loopback SOCKS5 relay and request metrics collector for PhoneUse."""
import argparse
import asyncio
import hmac
import ipaddress
import json
import os
import re
import secrets
import socket
import struct
import sys
import uuid
from urllib.parse import urlsplit, urlunsplit


def emit(event, **fields):
    try:
        print(json.dumps(dict(event=event, **fields), ensure_ascii=True), flush=True)
    except BrokenPipeError:
        # A closing window can discard the event stream before restoration completes.
        pass


class Pacer:
    """All connections share one byte budget per direction."""
    def __init__(self, kib):
        self.bytes_per_second = kib * 1024
        self.lock = asyncio.Lock()

    async def forward(self, reader, writer):
        while data := await reader.read(8192):
            if self.bytes_per_second:
                async with self.lock:
                    await asyncio.sleep(len(data) / self.bytes_per_second)
                    writer.write(data)
            else:
                writer.write(data)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()


def request_fields(record):
    url = urlsplit(record["url"])
    if url.scheme not in ("http", "https") or not url.hostname:
        raise ValueError("unsupported URL")
    host = url.hostname
    if ":" in host:
        host = "[" + host + "]"
    if url.port:
        host += f":{url.port}"
    method = record["method"]
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", method):
        raise ValueError("invalid method")
    return dict(method=method, url=urlunsplit((url.scheme, host, url.path, "", "")),
                status=int(record["status"]), millis=max(0, int(record["millis"])),
                received=max(0, int(record["received"])), sent=max(0, int(record["sent"])))


class Relay:
    def __init__(self, kib):
        self.token = secrets.token_hex(24)
        self.upload = Pacer(kib)
        self.download = Pacer(kib)
        self.connections = set()

    async def handle(self, reader, writer):
        task = asyncio.current_task()
        self.connections.add(task)
        try:
            async with asyncio.timeout(15):
                first = await reader.readexactly(1)
                if first == b"{":
                    record = json.loads(first + await reader.readuntil(b"\n"))
                    if not hmac.compare_digest(record["token"], self.token):
                        return
                    if record["event"] == "attached":
                        emit("attached")
                    elif record["event"] == "request":
                        emit("request", **request_fields(record))
                    return
                if first != b"\x05":
                    return
                upstream = await self.connect(reader, writer)
            if upstream:
                remote_reader, remote_writer = upstream
                try:
                    async with asyncio.TaskGroup() as group:
                        group.create_task(self.upload.forward(reader, remote_writer))
                        group.create_task(self.download.forward(remote_reader, writer))
                finally:
                    remote_writer.close()
        except (OSError, EOFError, ValueError, KeyError, TypeError, OverflowError,
                asyncio.IncompleteReadError, asyncio.LimitOverrunError, ExceptionGroup):
            pass
        finally:
            writer.close()
            self.connections.discard(task)

    async def connect(self, reader, writer):
        async def field():
            size = (await reader.readexactly(1))[0]
            return await reader.readexactly(size)

        if 2 not in await field():
            writer.write(b"\x05\xff")
            return
        writer.write(b"\x05\x02")
        version = await reader.readexactly(1)
        username, password = await field(), await field()
        if version != b"\x01" or username != b"phoneuse" or not hmac.compare_digest(password, self.token.encode()):
            writer.write(b"\x01\x01")
            return
        writer.write(b"\x01\x00")
        version, operation, reserved, kind = await reader.readexactly(4)
        reply = b"\x00\x01" + bytes(6)
        if (version, operation, reserved) != (5, 1, 0):
            writer.write(b"\x05\x07" + reply)
            return
        if kind in (1, 4):
            host = str(ipaddress.ip_address(await reader.readexactly(4 if kind == 1 else 16)))
        elif kind == 3:
            host = (await field()).decode("ascii")
        else:
            writer.write(b"\x05\x08" + reply)
            return
        port, = struct.unpack("!H", await reader.readexactly(2))
        try:
            upstream = await asyncio.open_connection(host, port)
        except OSError:
            writer.write(b"\x05\x05" + reply)
            return
        writer.write(b"\x05\x00" + reply)
        return upstream


async def run(args):
    relay = Relay(args.kib)
    async with await asyncio.start_server(relay.handle, "127.0.0.1", 0, family=socket.AF_INET,
                                         limit=16384) as server:
        port = server.sockets[0].getsockname()[1]
        env = os.environ.copy()
        for key, value in dict(PORT=str(port), TOKEN=relay.token, BUNDLE=args.bundle,
                               UDID=str(args.udid)).items():
            env["SIMCTL_CHILD_PHONEUSE_NETWORK_" + key] = value
        loop = asyncio.get_running_loop()
        closed = loop.create_future()
        def check_parent():
            if not os.read(0, 1024):
                loop.remove_reader(0)
                closed.set_result(None)

        loop.add_reader(0, check_parent)
        try:
            proc = await asyncio.create_subprocess_exec("/usr/bin/xcrun", "simctl", "launch",
                "--terminate-running-process", str(args.udid), args.bundle, env=env,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
            try:
                _, detail = await asyncio.wait_for(proc.communicate(), 40)
            except TimeoutError:
                proc.kill()
                await proc.wait()
                raise RuntimeError("启动应用超时，请从模拟器重新启动目标应用")
            if proc.returncode:
                raise RuntimeError(detail.decode(errors="replace").strip()[:600])
            emit("launched")
            await closed
            # Restore a fresh process with its ordinary URLSession configuration.
            server.close()
            for task in tuple(relay.connections):
                task.cancel()
            restore = await asyncio.create_subprocess_exec("/usr/bin/xcrun", "simctl", "launch",
                "--terminate-running-process", str(args.udid), args.bundle,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
            try:
                _, detail = await asyncio.wait_for(restore.communicate(), 30)
            except TimeoutError:
                restore.kill()
                await restore.wait()
                raise RuntimeError("恢复超时，请从模拟器重新启动目标应用")
            if restore.returncode:
                raise RuntimeError("请从模拟器重新启动目标应用：" + detail.decode(errors="replace")[:300])
        finally:
            loop.remove_reader(0)
            for task in tuple(relay.connections):
                task.cancel()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("udid", type=uuid.UUID)
    parser.add_argument("bundle")
    parser.add_argument("kib", type=int)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*", args.bundle) or args.kib < 0:
        parser.error("invalid bundle ID or bandwidth")
    try:
        asyncio.run(run(args))
    except (RuntimeError, OSError) as error:
        emit("error", message=str(error))
        sys.exit(1)
