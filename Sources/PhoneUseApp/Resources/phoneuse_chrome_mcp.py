"""Launch upstream Chrome DevTools MCP on stdio, backed by the PhoneUse daemon."""

import argparse
import asyncio
import contextlib
import json
import os
import secrets
from pathlib import Path
import signal
import socket
import sys
from types import SimpleNamespace

import uvicorn
from fastapi import FastAPI, WebSocket
from pymobiledevice3.services.web_protocol.cdp_browser import CdpBrowser
from pymobiledevice3.services.webinspector import WirTypes


async def rpc(path, method, **params):
    async with asyncio.timeout(35):
        reader, writer = await asyncio.open_unix_connection(path, limit=16 << 20)
        try:
            writer.write(json.dumps({"id": 1, "method": method, "params": params}).encode() + b"\n")
            await writer.drain()
            reply = json.loads(await reader.readline())
            if "error" in reply:
                raise RuntimeError(reply["error"]["message"])
            return reply["result"]
        finally:
            writer.close()
            await writer.wait_closed()


class PageChannel:
    """A CdpBrowser page target using the worker's already-translated CDP stream."""

    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer

    async def send(self, message):
        self.writer.write(json.dumps(message).encode() + b"\n")
        await self.writer.drain()

    async def receive(self):
        line = await self.reader.readline()
        if not line:
            raise EOFError("PhoneUse page disconnected")
        return json.loads(line)

    async def close(self):
        self.writer.close()
        await self.writer.wait_closed()


class DeviceBrowser(CdpBrowser):
    def __init__(self, ws, path, device, page_id=None):
        super().__init__(self, ws)
        self.connection_id = secrets.token_hex(16)
        self.path, self.device = path, device
        self.page_id = page_id
        self.retry_after = {}
        self.pages = {}
        for method in ("Target.createTarget", "Target.closeTarget", "Target.createBrowserContext",
                       "Target.disposeBrowserContext", "Browser.close"):
            self._handlers[method] = self._unsupported

    async def _unsupported(self, message):
        await self._send({**{k: message[k] for k in ("id", "sessionId") if k in message},
                          "error": {"code": -32601, "message": f"{message['method']} is unavailable on iOS."}})

    def find_page_id(self, page_id):
        return self.pages[page_id]

    def _list_pages(self):
        return self.pages

    async def _refresh_targets(self, announce_all=False):
        listing = await rpc(self.path, "webInspector", udid=self.device, action="list")
        now = asyncio.get_running_loop().time()
        self.retry_after = {k: t for k, t in self.retry_after.items() if t > now}
        self.pages = {
            row["page_id"]: (SimpleNamespace(name=row["bundle_id"]),
                             SimpleNamespace(type_=WirTypes.WEB_PAGE, web_title=row["title"], web_url=row["url"]))
            for row in listing["pages"] if row["kind"] == "page" and (not row["attached"] or row["attached_here"])
            and (not self.page_id or self.page_id == row["page_id"]) and row["page_id"] not in self.retry_after
        }
        await self._sync_targets(announce_all=announce_all)

    async def _target_set_auto_attach(self, message):
        # These are live user pages. Keep discovery/attachment scoped to pages
        # without enabling device-wide pause-on-launch for other applications.
        await super()._target_set_auto_attach({
            **message, "params": {**message["params"], "waitForDebuggerOnStart": False},
        })

    async def _create_target(self, page_id, application, page, waiting_for_debugger, lock):
        try:
            endpoint = await rpc(self.path, "webInspector", udid=self.device,
                                 action="frontend", page_id=page_id, engine="cdp")
            if "url" in endpoint or "commands" in endpoint:
                raise RuntimeError("Start the updated PhoneUse app to use its shared CDP channel.")
            return PageChannel(*await asyncio.open_unix_connection(endpoint["socket"], limit=64 << 20))
        except (RuntimeError, OSError) as error:
            lock.release()
            self.retry_after[page_id] = asyncio.get_running_loop().time() + 30
            await self._destroy_target(page_id)
            print(f"PhoneUse CDP: cannot attach to {page_id}: {error}", file=sys.stderr)
            return None
        except asyncio.CancelledError:
            lock.release()
            raise

    async def _pump(self, attachment):
        try:
            await super()._pump(attachment)
        except (ConnectionError, EOFError):
            pass  # Target discovery reports the closed page.


async def choose_device(path, requested):
    devices = (await rpc(path, "listDevices"))["devices"]
    ready = [d["udid"] for d in devices if d["platform"] == "ios" and
             d["connection"] != "simulator" and d["state"] == "ready"]
    if requested in ready:
        return requested
    if not requested and len(ready) == 1:
        return ready[0]
    raise RuntimeError("Select a ready physical iPhone/iPad with chrome-devtools --device UDID.")


async def run(args):
    token = secrets.token_urlsafe(32)
    api = FastAPI(openapi_url=None, docs_url=None, redoc_url=None)

    @api.websocket("/devtools/browser/{key}")
    async def connect(ws: WebSocket, key: str):
        if not secrets.compare_digest(key, token) or ws.headers.get("origin"):
            await ws.close()
            return
        try:
            device = await choose_device(args.socket, args.device)
            await ws.accept()
            browser = DeviceBrowser(ws, args.socket, device, args.page)
            try:
                await browser.run()
            finally:
                await browser.close()
        except Exception as error:
            print(f"PhoneUse CDP: {error}", file=sys.stderr)
            with contextlib.suppress(Exception):
                await ws.close(code=1011)

    runtime = Path(args.runtime)
    argv = [str(runtime / "node"), str(runtime / "package/build/src/bin/chrome-devtools-mcp.js")]
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        endpoint = f"ws://127.0.0.1:{listener.getsockname()[1]}/devtools/browser/{token}"
        server = uvicorn.Server(uvicorn.Config(api, access_log=False, log_level="warning", ws="wsproto",
                                               lifespan="off", timeout_graceful_shutdown=2))
        server.capture_signals = contextlib.nullcontext
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        loop.add_signal_handler(signal.SIGTERM, stop.set)
        proc = await asyncio.create_subprocess_exec(*argv, "--wsEndpoint", endpoint,
                    "--no-usage-statistics", "--no-performance-crux", start_new_session=True,
                    env={**os.environ, "CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS": "1"})
        serving = asyncio.create_task(server.serve(sockets=[listener]))
        exited = asyncio.create_task(proc.wait())
        stopping = asyncio.create_task(stop.wait())
        try:
            await asyncio.wait((serving, exited, stopping), return_when=asyncio.FIRST_COMPLETED)
        finally:
            stopping.cancel()
            server.should_exit = True
            if proc.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGTERM)
                try:
                    await asyncio.wait_for(asyncio.shield(exited), 3)
                except TimeoutError:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(proc.pid, signal.SIGKILL)
            await serving
            await exited
            loop.remove_signal_handler(signal.SIGTERM)
        return proc.returncode


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--device")
    parser.add_argument("--page", help="Only expose this PhoneUse list_web_pages page_id")
    try:
        sys.exit(asyncio.run(run(parser.parse_args())))
    except (OSError, RuntimeError) as error:
        sys.exit(str(error))
