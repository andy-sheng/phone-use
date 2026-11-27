"""Safari and inspectable WebViews on one physical iOS device."""

import asyncio
import contextlib
import json
import re
import uuid
from collections import OrderedDict, deque

from pymobiledevice3.exceptions import WebInspectorNotEnabledError
from pymobiledevice3.services.webinspector import WebinspectorService, WirTypes, make_target_id

from devicehubd.protocol import RpcError
from devicehubd.web_frontend import InspectorFrontend
from devicehubd.web_protocol import PageSocket, REFERENCE, protocol_catalog

TARGET_KINDS = {WirTypes.WEB: "page", WirTypes.WEB_PAGE: "page", WirTypes.PAGE: "page",
                WirTypes.JAVASCRIPT: "javascript", WirTypes.SERVICE_WORKER: "service-worker", WirTypes.ITML: "itml"}
ENABLE_HINT = "Enable Web Inspector in Settings > Apps > Safari > Advanced on the iPhone."


def page_id(pair):
    return make_target_id(pair.application.id_, str(pair.page.id_))


def display_text(value, limit):
    # JS strings can contain lone surrogates. The daemon wire format requires UTF-8.
    return str(value)[:limit].encode("utf-8", "replace").decode()


class WebInspector:
    def __init__(self, rsd):
        self.rsd = rsd
        self.lock = asyncio.Lock()
        self.service = None
        self.discovery_expiry = None
        self.session = None
        self.clients = {}
        self.events = deque(maxlen=256)
        self.event_cursor = 0
        self.payloads = OrderedDict()
        self.payload_size = 0
        self.messages = deque(maxlen=256)
        self.sequence = 0

    async def _expire_discovery(self):
        await asyncio.sleep(30)
        async with self.lock:
            if self.session is None:
                await self.close()

    async def close(self):
        if self.discovery_expiry and self.discovery_expiry is not asyncio.current_task():
            self.discovery_expiry.cancel()
        self.discovery_expiry = None
        session, service = self.session, self.service
        self.session = self.service = None
        self.clients.clear()
        self.events.clear()
        self.event_cursor = 0
        self.payloads.clear()
        self.payload_size = 0
        self.messages.clear()
        self.sequence = 0
        if session:
            for frontend in session.frontends:
                frontend.close()
            session.frontends.clear()
            with contextlib.suppress(Exception):
                async with asyncio.timeout(2):
                    await session.close()
        if service:
            with contextlib.suppress(Exception):
                async with asyncio.timeout(2):
                    await service.close()

    def _live(self):
        if not self.service.is_connected:
            return False
        if not self.session:
            return True
        pages = self.service.application_pages.get(self.session.app.id_, {})
        return pages.get(str(self.session.page.id_)) is self.session.page

    def _pack(self, value):
        # ASCII JSON permits exact reassembly at any offset, including inside a Unicode escape.
        encoded = json.dumps(value, separators=(",", ":"), allow_nan=False)
        if len(encoded) <= 16384:
            return {"result": json.loads(json.dumps(value, ensure_ascii=False).encode("utf-8", "replace"))}
        budget = 64 * 1024 * 1024
        if len(encoded) > budget:
            raise RpcError("resultTooLarge", "Inspector payload exceeds 64 MiB.")
        while self.payloads and (len(self.payloads) >= 64 or self.payload_size + len(encoded) > budget):
            _, old = self.payloads.popitem(last=False)
            self.payload_size -= len(old)
        key = str(uuid.uuid4())
        self.payloads[key] = encoded
        self.payload_size += len(encoded)
        return {"data_id": key, "length": len(encoded)}

    def _event(self, method, params, target):
        self.event_cursor += 1
        entry = {"cursor": self.event_cursor, "method": method, "target": target or "root"}
        try:
            entry.update(self._pack(params))
        except RpcError as error:
            entry["error"] = str(error)
        self.events.append(entry)
        if method in ("Console.messageAdded", "Console.messageRepeatCountUpdated", "Console.messagesCleared"):
            self._console_event({"method": method, "params": params})

    def _console_event(self, event):
        params = event["params"]
        message = params.get("message", {})
        self.sequence += 1
        entry = {"cursor": self.sequence, "event": event["method"]}
        if message:
            text = " ".join(display_text(arg.get("description", arg.get("value", arg.get("type", ""))), 2048)
                            for arg in message.get("parameters", [])[:16])
            entry.update(level=message.get("level"), text=display_text(text or message.get("text", ""), 2048))
            for key in ("source", "url", "line", "column", "timestamp"):
                if key in message:
                    value = message[key]
                    entry[key] = display_text(value, 512) if isinstance(value, str) else value
        if "count" in params:
            entry["count"] = params["count"]
        self.messages.append(entry)

    async def command(self, params):
        action = params.get("action")
        if action == "catalog":
            source, domains = protocol_catalog(str(getattr(self.rsd, "product_version", "")))
            result = {"source": source, "reference": REFERENCE, "device_version": str(self.rsd.product_version)}
            domain = params.get("domain")
            if domain:
                if domain not in domains:
                    raise RpcError("unknownDomain", "Domain not in the Mac's WebKit reference. Raw commands remain available.")
                result.update(domains[domain])
            else:
                result["domains"] = sorted(domains)
            return result
        if action in ("send", "evaluate", "events", "logs", "data"):
            self._check_session(params)
            # Allow reading paused events and resuming while another command awaits its reply.
            try:
                async with asyncio.timeout(30):
                    return await self._session_command(action, params)
            except TimeoutError as error:
                raise RpcError("inspectorTimeout", "No WebKit reply within 30 seconds. The command may have run.") from error
        try:
            async with asyncio.timeout(5):
                await self.lock.acquire()
        except TimeoutError as error:
            raise RpcError("inspectorBusy", "Another Web Inspector operation is in progress.") from error
        try:
            if self.discovery_expiry:
                self.discovery_expiry.cancel()
                self.discovery_expiry = None
            if self.service and not self._live():
                await self.close()
            async with asyncio.timeout(12):
                result = await self._command(params)
                # Reuse discovery for a following attach. iOS rate-limits repeated handshakes.
                if action == "list" and self.session is None:
                    self.discovery_expiry = asyncio.create_task(self._expire_discovery())
                return result
        except WebInspectorNotEnabledError as error:
            raise RpcError("inspectorDisabled", ENABLE_HINT) from error
        except TimeoutError as error:
            await self.close()
            raise RpcError("inspectorTimeout", f"Web Inspector timed out. {ENABLE_HINT} List pages and attach again.") from error
        finally:
            if self.session is None and self.service and self.discovery_expiry is None:
                await self.close()
            self.lock.release()

    async def _command(self, params):
        action = params.get("action")
        if action in ("list", "attach", "frontend"):
            pages = await self._pages()
            if action == "list":
                return {"pages": [{"page_id": page_id(pair), "bundle_id": pair.application.bundle,
                                   "kind": TARGET_KINDS[pair.page.type_], "title": display_text(pair.page.web_title, 512),
                                   "url": display_text(pair.page.web_url, 2048),
                                   "attached": bool(pair.page.web_connection_id),
                                   "attached_here": self.session is not None and self.session.page is pair.page} for pair in pages]}
            if action == "frontend":
                return await self._open_frontend(pages, params.get("page_id"), params.get("engine", "webkit"))
            return await self._attach(pages, params.get("page_id"), params.get("client", "mcp"))

        self._check_session(params)
        if action == "detach":
            client = next(key for key, token in self.clients.items() if token == params["session_id"])
            del self.clients[client]
            if not self.clients:
                await self.close()
            return {"detached": True}
        raise RpcError("invalidParams", "Unknown Web Inspector action.")

    async def _open_frontend(self, pages, page, engine):
        if engine not in ("chrome", "webkit", "cdp"):
            raise RpcError("invalidParams", "Unknown inspector frontend.")
        if engine != "cdp" and self.session and any(f.panel for f in self.session.frontends):
            raise RpcError("inspectorBusy", "The Web Inspector panel is already open.")
        client = str(uuid.uuid4())
        await self._attach(pages, page, client)

        async def release(frontend):
            async with self.lock:
                if self.session and frontend in self.session.frontends:
                    self.session.frontends.remove(frontend)
                    frontend.close()
                    self.clients.pop(client, None)
                    if not self.clients:
                        await self.close()

        frontend = None
        try:
            frontend_type = InspectorFrontend
            if engine in ("chrome", "cdp"):
                from devicehubd.chrome_frontend import ChromeFrontend
                frontend_type = ChromeFrontend
            frontend = frontend_type(self.session, self._live, release, self._frontend_console_history)
            frontend.panel = engine != "cdp"
            self.session.frontends.add(frontend)
            await frontend.start()
            if engine == "cdp":
                return {"socket": frontend.path}
            if engine == "chrome":
                from pymobiledevice3.services.web_protocol.cdp_server import DEVTOOLS_FRONTEND_HOST, DEVTOOLS_FRONTEND_REV
                entry = "js_app.html" if self.session.page.type_ == WirTypes.JAVASCRIPT else "inspector.html"
                return {"socket": frontend.path,
                        "url": f"https://{DEVTOOLS_FRONTEND_HOST}/serve_rev/@{DEVTOOLS_FRONTEND_REV}/{entry}"}
            source, _ = protocol_catalog(str(self.rsd.product_version))
            kind = "web-page" if self.session.target else TARGET_KINDS[self.session.page.type_]
            return {"socket": frontend.path, "kind": kind, "commands": "Protocol/" + source}
        except BaseException:
            if frontend:
                frontend.close()
                self.session.frontends.discard(frontend)
            self.clients.pop(client, None)
            if not self.clients:
                await self.close()
            raise

    def _frontend_console_history(self):
        # Console.enable ran when the first client attached. A second enable need not
        # replay stored messages, so bootstrap the native console from the shared buffer.
        for event in self.events:
            if not event["method"].startswith("Console."):
                continue
            params = event.get("result")
            if params is None:
                raw = self.payloads.get(event.get("data_id"))
                if raw is None:
                    continue
                params = json.loads(raw)
            message = {"method": event["method"], "params": params}
            target = event["target"]
            if target == "root":
                yield message
            elif target in self.session.targets:
                yield {"method": "Target.dispatchMessageFromTarget",
                       "params": {"targetId": target, "message": json.dumps(message)}}

    def _check_session(self, params):
        if not self.session or params.get("session_id") not in self.clients.values() or not self._live():
            raise RpcError("invalidSession", "This session has ended or belongs to another device. List pages and attach again.")

    async def _session_command(self, action, params):
        if action == "logs":
            return self._logs(params.get("after", 0))
        if action == "evaluate":
            return await self._evaluate(params.get("expression"))
        if action == "events":
            after = params.get("after", 0)
            if type(after) is not int or not 0 <= after <= self.event_cursor:
                raise RpcError("invalidParams", "Invalid event cursor for this session.")
            domain = params.get("domain")
            rows = [e for e in self.events if e["cursor"] > after and
                    (not domain or e["method"].split(".")[0] == domain)]
            batch = rows[:16]
            return {"events": batch, "next_cursor": batch[-1]["cursor"] if len(rows) > 16 else self.event_cursor,
                    "has_more": len(rows) > 16, "dropped": max(0, self.event_cursor - len(self.events) - after)}
        if action == "data":
            raw = self.payloads.get(params.get("data_id"))
            if raw is None:
                raise RpcError("expiredData", "Inspector data has expired.")
            offset = params.get("offset", 0)
            if type(offset) is not int or not 0 <= offset <= len(raw):
                raise RpcError("invalidParams", "Invalid data offset.")
            chunk = raw[offset:offset + 16384]
            return {"text": chunk, "next_offset": offset + len(chunk), "length": len(raw)}
        method, arguments = params.get("method"), params.get("params", {})
        if not isinstance(method, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*\.[A-Za-z][A-Za-z0-9]*", method):
            raise RpcError("invalidParams", "Use a WebKit Domain.command method.")
        if not isinstance(arguments, dict):
            raise RpcError("invalidParams", "Command params must be an object.")
        target = params.get("target")
        if not target and method.split(".")[0] in ("Target", "Browser"):
            target = "root"
        session = self.session
        reply = await session.command(method, arguments, target)
        if self.session is not session:
            raise RpcError("invalidSession", "Inspector session ended during the command.")
        return self._pack(reply)

    async def _pages(self):
        if self.service is None:
            self.service = WebinspectorService(self.rsd)
            await self.service.connect()
        return [pair for pair in await self.service.get_open_application_pages(timeout=0.5)
                if pair.page.type_ in TARGET_KINDS]

    async def _attach(self, pages, target, client):
        pair = next((p for p in pages if page_id(p) == target), None)
        if pair is None:
            raise RpcError("pageUnavailable", "Page closed or unknown. List the inspectable pages again.")
        if self.session and self.session.page is not pair.page:
            raise RpcError("inspectorBusy", "Detach the current PhoneUse Web Inspector session first.")
        if not self.session:
            if pair.page.web_connection_id:
                raise RpcError("inspectorBusy", "The page is open in another debugger. Detach it first.")
            self.session = PageSocket(self.service, pair.application, pair.page, self._event)
            try:
                await self.session.open()
                await self.session.command("Console.enable", {})
            except BaseException:
                await self.close()
                raise
        token = self.clients.setdefault(client, str(uuid.uuid4()))
        return {"session_id": token, "page_id": page_id(pair), "target": self.session.target or "root"}

    def _logs(self, after):
        if type(after) is not int or not 0 <= after <= self.sequence:
            raise RpcError("invalidParams", "Use zero or a cursor returned by this session.")
        entries = [entry for entry in self.messages if entry["cursor"] > after][:32]
        cursor = entries[-1]["cursor"] if entries else after
        return {"messages": entries, "next_cursor": cursor, "has_more": cursor < self.sequence,
                "dropped": max(0, self.sequence - len(self.messages) - after)}

    async def _evaluate(self, expression):
        if not isinstance(expression, str) or not expression.strip() or len(expression.encode()) > 8192:
            raise RpcError("invalidParams", "Supply a JavaScript expression of up to 8192 UTF-8 bytes.")
        result = await self.session.command("Runtime.evaluate", {"expression": expression, "returnByValue": True})
        remote = result["result"]
        if result.get("wasThrown"):
            raise RpcError("javascriptException", display_text(remote.get("description", remote.get("value", "JavaScript exception")), 2048))
        output = {key: remote[key] for key in ("type", "subtype", "value", "description") if key in remote}
        encoded = json.dumps(output, ensure_ascii=False, allow_nan=False).encode("utf-8", "replace")
        if len(encoded) > 32 * 1024:
            raise RpcError("resultTooLarge", "Result exceeds 32 KiB. Return a smaller value.")
        return json.loads(encoded)


class DeviceWebInspector:
    """Route clients of the same page to one page socket, including browser auto-attach."""

    def __init__(self, rsd):
        self.rsd = rsd
        self.discovery = WebInspector(rsd)
        self.pages = {}

    async def close(self):
        await asyncio.gather(*(owner.close() for owner in {*self.pages.values(), self.discovery}))
        self.pages.clear()

    async def command(self, params):
        for key, owner in list(self.pages.items()):
            if not owner.lock.locked() and owner.service is None:
                del self.pages[key]
        action = params.get("action")
        if action in ("catalog", "list"):
            owner = next((p for p in self.pages.values() if p.session and p._live()), self.discovery)
            result = await owner.command(params)
            for row in result.get("pages", []):
                attached = self.pages.get(row["page_id"])
                row["attached_here"] = bool(attached and attached.session and attached._live())
            return result
        if action in ("attach", "frontend"):
            key = params.get("page_id")
            if not isinstance(key, str):
                raise RpcError("invalidParams", "A page ID is required.")
            if key not in self.pages:
                # Transfer discovery's connected service to the first page; each other
                # page needs its own WebKit receive handler on the same device transport.
                self.pages[key] = self.discovery
                self.discovery = WebInspector(self.rsd)
            return await self.pages[key].command(params)
        token = params.get("session_id")
        owner = next((p for p in self.pages.values() if token in p.clients.values()), None)
        if owner is None:
            raise RpcError("invalidSession", "Unknown or expired Web Inspector session.")
        return await owner.command(params)
