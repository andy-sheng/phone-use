"""Stream the system Web Inspector frontend's ordered protocol messages on a private Unix socket."""

import asyncio
import json
import tempfile
from pathlib import Path


class InspectorFrontend:
    def __init__(self, session, live, release, console_history):
        self.session = session
        self.live = live
        self.console_history = console_history
        self.release = release
        self.directory = tempfile.TemporaryDirectory(prefix="phoneuse-inspector-", dir="/tmp")
        self.path = str(Path(self.directory.name) / "frontend.sock")
        self.server = self.writer = self.watchdog = None
        self.requests = {}

    async def start(self):
        self.server = await asyncio.start_unix_server(self.serve, self.path, limit=64 << 20)
        self.watchdog = asyncio.create_task(self.watch())

    async def watch(self):
        try:
            for _ in range(15):
                await asyncio.sleep(1)
                if self.writer or not self.live():
                    break
            while self.writer and self.live():
                await asyncio.sleep(1)
            await self.release(self)
        except asyncio.CancelledError:
            pass

    def close(self):
        if self.watchdog and self.watchdog is not asyncio.current_task():
            self.watchdog.cancel()
        if self.server:
            self.server.close()
        if self.writer:
            self.writer.close()
        self.directory.cleanup()
        self.requests.clear()

    async def serve(self, reader, writer):
        if self.writer or self not in self.session.frontends:
            writer.close()
            return
        self.writer = writer
        self.server.close()
        try:
            await self.run(reader)
        except (ConnectionError, ValueError, KeyError, TypeError):
            pass
        finally:
            writer.close()
            await self.release(self)

    async def run(self, reader):
        # targetCreated arrives before PhoneUse can hand the socket path to its frontend.
        for info in self.session.targets.values():
            self.deliver({"method": "Target.targetCreated", "params": {"targetInfo": info}})
        for message in self.console_history():
            self.deliver(message)
        while line := await reader.readline():
            message = json.loads(line)
            await self.forward(message)

    async def forward(self, message):
        self.translate_request(message)
        await self.session.service.send_socket_data(
            self.session.id, self.session.app.id_, self.session.page.id_, message)

    def translate_request(self, message, target=None):
        # Both WebKit and MCP start at small integer IDs. Allocate from the page socket's
        # sequence, including for the independently numbered inner Target message.
        wire_id = self.session.next_id()
        self.requests[target, wire_id] = message["id"]
        message["id"] = wire_id
        if message["method"] == "Target.sendMessageToTarget":
            params = message["params"]
            nested = json.loads(params["message"])
            self.translate_request(nested, params["targetId"])
            params["message"] = json.dumps(nested)

    def reply(self, message, target):
        original = self.requests.pop((target, message["id"]), None)
        if original is None:
            return False
        message = {**message, "id": original}
        if target is not None:
            message = {"method": "Target.dispatchMessageFromTarget",
                       "params": {"targetId": target, "message": json.dumps(message)}}
        self.deliver(message)
        return True

    def deliver(self, message):
        if self.writer and not self.writer.is_closing():
            # A stalled UI must never block MCP or the device's receive loop.
            if self.writer.transport.get_write_buffer_size() > 64 << 20:
                self.writer.transport.abort()
            else:
                self.writer.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")
