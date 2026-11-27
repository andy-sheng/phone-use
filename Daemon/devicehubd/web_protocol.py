"""WebKit page socket and the protocol signatures installed with macOS Safari."""

import asyncio
import json
import re
import uuid
from functools import lru_cache
from pathlib import Path

from pymobiledevice3.services.webinspector import WirTypes

from devicehubd.protocol import RpcError

PROTOCOL = Path("/System/Library/PrivateFrameworks/WebInspectorUI.framework/Resources/Protocol")
REFERENCE = "https://github.com/WebKit/WebKit/tree/main/Source/JavaScriptCore/inspector/protocol"


@lru_cache(maxsize=8)
def protocol_catalog(version):
    # Read the host's generated declarations as data. Device builds can differ from this reference.
    parts = re.match(r"\d+(?:\.\d+)*", version or "")
    device = tuple(map(int, parts[0].split("."))) if parts else ()
    legacy = PROTOCOL / "Legacy/iOS"
    versions = sorted((tuple(map(int, p.name.split("."))), p)
                      for p in legacy.glob("*") if re.fullmatch(r"\d+(?:\.\d+)*", p.name))
    candidates = [p for number, p in versions if number <= device]
    path = (candidates[-1] if candidates else PROTOCOL) / "InspectorBackendCommands.js"
    source = str(path.relative_to(PROTOCOL))
    domains = {}
    if path.is_file():
        for kind, args in re.findall(r'^InspectorBackend\.register(Domain|Command|Event)\((.*)\);$', path.read_text(), re.M):
            try:
                name, *fields = json.loads("[" + args + "]")
            except ValueError:
                continue
            domain = name.split(".")[0]
            entry = domains.setdefault(domain, {"targets": [], "commands": [], "events": []})
            if kind == "Domain":
                entry["targets"] = fields[0]
            elif kind == "Command":
                entry["commands"].append({"method": name, "targets": fields[0] or entry["targets"],
                                          "params": fields[1], "returns": fields[2]})
            elif kind == "Event":
                entry["events"].append({"method": name, "params": fields[-1]})
    return source, domains


class PageSocket:
    """Route each reply to its caller, including when execution pauses during another call."""

    def __init__(self, service, app, page, on_event):
        self.service, self.app, self.page = service, app, page
        self.id = str(uuid.uuid4()).upper()
        self.on_event = on_event
        self.target = None
        self.targets = {}
        self.frontends = set()
        self.ready = asyncio.Event()
        self.serial = 0
        self.pending = {}
        self.closed = False

    async def open(self):
        self.service.receive_handlers["_rpc_applicationSentData:"] = self.receive
        await self.service.setup_inspector_socket(self.id, self.app.id_, self.page.id_)
        if self.page.type_ in (WirTypes.WEB_PAGE, WirTypes.WEB):
            await self.ready.wait()

    async def receive(self, packet):
        if packet.get("WIRDestinationKey") not in (None, "", self.id) or self.closed:
            return
        message = json.loads(packet["WIRMessageDataKey"])
        packet_message = message
        method = message.get("method")
        params = message.get("params", {})
        target = None
        if method == "Target.dispatchMessageFromTarget":
            target = params["targetId"]
            message = json.loads(params["message"])
        elif method == "Target.targetCreated":
            info = params["targetInfo"]
            self.targets[info["targetId"]] = info.copy()
            if self.target is None and info.get("type", "page") == "page":
                self.target = info["targetId"]
                self.ready.set()
        elif method == "Target.targetDestroyed":
            self.targets.pop(params["targetId"], None)
        elif method == "Target.didCommitProvisionalTarget":
            self.targets.pop(params["oldTargetId"], None)
            if info := self.targets.get(params["newTargetId"]):
                info.pop("isProvisional", None)
            self.target = params["newTargetId"]
        if "id" in message:
            if any(frontend.reply(message, target) for frontend in self.frontends):
                return
            pending = self.pending.get((target, message["id"]))
            if pending:
                future, envelope = pending
                if not future.done():
                    if "error" in message:
                        error = message["error"]
                        future.set_exception(RpcError("webProtocol", f"{error.get('code', '')} {error.get('message', '')}"))
                    elif not envelope:
                        future.set_result(message.get("result", {}))
            elif target is not None:
                # A caller can also send its own nested Target protocol message.
                self.on_event("Target.dispatchMessageFromTarget", params, None)
        else:
            for frontend in self.frontends:
                frontend.deliver(packet_message)
            self.on_event(message["method"], message.get("params", {}), target)

    def next_id(self):
        self.serial += 1
        return self.serial

    async def command(self, method, params, target=None):
        if self.closed:
            raise RpcError("invalidSession", "Web Inspector session has closed.")
        inner, outer = self.next_id(), self.next_id()
        destination = None if target == "root" else target or self.target
        message = {"id": inner, "method": method, "params": params}
        future = asyncio.get_running_loop().create_future()
        self.pending[destination, inner] = (future, False)
        if destination is not None:
            message = {"id": outer, "method": "Target.sendMessageToTarget",
                       "params": {"targetId": destination, "message": json.dumps(message)}}
            self.pending[None, outer] = (future, True)
        try:
            await self.service.send_socket_data(self.id, self.app.id_, self.page.id_, message)
            return await future
        finally:
            self.pending.pop((destination, inner), None)
            self.pending.pop((None, outer), None)

    async def close(self):
        self.closed = True
        for future, _ in self.pending.values():
            if not future.done():
                future.set_exception(RpcError("invalidSession", "Web Inspector session has closed."))
        await self.service.teardown_inspector_socket(self.id, self.app.id_, self.page.id_)
