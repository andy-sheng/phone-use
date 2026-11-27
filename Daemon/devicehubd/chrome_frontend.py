"""Run pymobiledevice3's CDP translator on PhoneUse's existing WebKit page socket."""

import asyncio
import json
from collections import deque

from pymobiledevice3.services.web_protocol.cdp_target import CdpTarget
from pymobiledevice3.services.web_protocol.session_protocol import SessionProtocol
from pymobiledevice3.services.webinspector import WirTypes

from devicehubd.cdp_accessibility import AccessibilityTree
from devicehubd.web_frontend import InspectorFrontend


class ChromeFrontend(InspectorFrontend):
    def __init__(self, session, live, release, console_history):
        super().__init__(session, live, release, console_history)
        self.events = deque()
        self.wir_message_results = {}

    # SessionProtocol's transport. Each request (including nested Target messages)
    # is renumbered by InspectorFrontend before sharing the wire with MCP.
    async def send_socket_data(self, socket_id, app_id, page_id, message):
        await self.forward(message)

    def session_events(self, socket_id):
        return self.events

    async def teardown_inspector_socket(self, socket_id, app_id, page_id):
        # WebInspector owns the physical socket until the last client releases it.
        pass

    def deliver(self, message):
        if not self.writer or self.writer.is_closing():
            return
        if "id" in message:
            # Multiplexed targets read the inner reply; JSContexts use a flat result table.
            if self.session.page.type_ == WirTypes.JAVASCRIPT:
                self.wir_message_results[message["id"]] = message
        else:
            self.events.append(message)

    async def run(self, reader):
        session = self.session
        protocol = SessionProtocol(self, session.id, session.app, session.page, method_prefix="")
        target = CdpTarget(protocol, session.target or f"jscontext:{session.app.id_}:{session.page.id_}")
        if session.page.type_ in (WirTypes.WEB, WirTypes.WEB_PAGE, WirTypes.PAGE):
            AccessibilityTree(session, target)
        for message in self.console_history():
            self.deliver(message)

        async def from_ui():
            while line := await reader.readline():
                await target.send(json.loads(line))

        async def to_ui():
            while True:
                message = await target.receive()
                self.writer.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")
                await self.writer.drain()

        tasks = [asyncio.create_task(from_ui()), asyncio.create_task(to_ui())]
        try:
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await target.close()
