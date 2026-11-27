import asyncio
import asyncio
import json
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from pymobiledevice3.services.webinspector import WirTypes

from devicehubd.protocol import RpcError
from devicehubd.web_inspector import DeviceWebInspector, WebInspector


class WebInspectorTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.inspector = WebInspector(SimpleNamespace(product_version="26.5"))
        self.page = SimpleNamespace(id_=1, type_=WirTypes.WEB_PAGE, web_title="fixture",
                                    web_url="about:blank", web_connection_id="")
        self.app = SimpleNamespace(id_="PID:5", bundle="com.apple.mobilesafari")
        pair = SimpleNamespace(page=self.page, application=self.app)
        self.service = AsyncMock(is_connected=True, application_pages={"PID:5": {"1": self.page}})
        self.service.get_open_application_pages.return_value = [pair]
        self.service.receive_handlers = {}
        self.service.setup_inspector_socket.side_effect = self.open_socket
        self.service.send_socket_data.side_effect = self.send
        self.reply = {}
        patcher = patch("devicehubd.web_inspector.WebinspectorService", return_value=self.service)
        patcher.start()
        self.addCleanup(patcher.stop)

    async def asyncTearDown(self):
        await self.inspector.close()

    async def receive(self, message):
        await self.service.receive_handlers["_rpc_applicationSentData:"]({
            "WIRDestinationKey": self.socket_id, "WIRMessageDataKey": json.dumps(message)})

    async def open_socket(self, socket_id, app, page):
        self.socket_id = socket_id
        await self.receive({"method": "Target.targetCreated", "params": {
            "targetInfo": {"targetId": "page:1", "type": "page"}}})

    async def send(self, socket_id, app, page, message):
        if message["method"] != "Target.sendMessageToTarget":
            await self.receive({"id": message["id"], "result": {"root": True}})
            return
        wrapper = message["params"]
        inner = json.loads(wrapper["message"])
        await self.receive({"id": message["id"], "result": {}})
        await self.receive({"method": "Target.dispatchMessageFromTarget", "params": {
            "targetId": wrapper["targetId"], "message": json.dumps({"id": inner["id"], "result": self.reply})}})

    async def command(self, action, **params):
        return await self.inspector.command({"action": action, **params})

    async def attach(self):
        return (await self.command("attach", page_id="PID:5:1"))["session_id"]

    async def test_list_attach_retry_detach_and_stale_session(self):
        pages = (await self.command("list"))["pages"]
        self.assertEqual(pages[0]["page_id"], "PID:5:1")
        self.service.close.assert_not_awaited()
        token = await self.attach()
        self.service.connect.assert_awaited_once()
        self.assertEqual(token, await self.attach())
        self.service.setup_inspector_socket.assert_awaited_once()
        with self.assertRaises(RpcError):
            await self.command("detach", session_id="old")
        await self.command("detach", session_id=token)
        self.service.teardown_inspector_socket.assert_awaited_once_with(self.socket_id, "PID:5", 1)
        with self.assertRaises(RpcError):
            await self.command("evaluate", session_id=token, expression="1+1")

    async def test_closed_page_and_conflicting_debugger(self):
        self.page.web_connection_id = "external"
        with self.assertRaisesRegex(RpcError, "another debugger"):
            await self.attach()
        self.service.setup_inspector_socket.assert_not_awaited()
        self.page.web_connection_id = ""
        token = await self.attach()
        self.service.application_pages.clear()
        with self.assertRaisesRegex(RpcError, "session has ended"):
            await self.command("logs", session_id=token)

    async def test_evaluate_value_and_thrown_primitive(self):
        token = await self.attach()
        for remote, threw in [({"type": "object", "value": {"count": 2}}, False),
                              ({"type": "object", "subtype": "null", "value": None}, False),
                              ({"type": "undefined"}, False),
                              ({"type": "string", "value": "fixture error"}, True)]:
            self.reply = {"result": remote, "wasThrown": threw}
            if threw:
                with self.assertRaisesRegex(RpcError, "fixture error"):
                    await self.command("evaluate", session_id=token, expression="throw 'fixture error'")
            else:
                self.assertEqual(await self.command("evaluate", session_id=token, expression="fixture"), remote)

    async def test_log_cursor_replay_and_eviction(self):
        token = await self.attach()
        for i in range(260):
            self.inspector._event("Console.messageAdded", {"message": {
                "level": "log", "parameters": [{"value": "index"}, {"value": i}]}}, "page:1")
        events = await self.command("logs", session_id=token)
        self.assertEqual((events["dropped"], events["next_cursor"], events["has_more"]), (4, 36, True))
        self.assertEqual(events["messages"][0]["text"], "index 4")
        final = await self.command("logs", session_id=token, after=259)
        self.assertEqual(final["messages"][0]["text"], "index 259")
        self.assertFalse(final["has_more"])
        self.assertEqual((await self.command("logs", session_id=token, after=260))["messages"], [])


    async def test_shared_ui_lease_filtered_events_and_chunked_data(self):
        token = await self.attach()
        ui = (await self.command("attach", page_id="PID:5:1", client="ui"))["session_id"]
        self.assertNotEqual(ui, token)
        await self.command("detach", session_id=ui)
        self.service.teardown_inspector_socket.assert_not_awaited()
        with self.assertRaises(RpcError):
            await self.command("logs", session_id=ui)
        self.reply = {"body": "資料" * 4000}
        large = await self.command("send", session_id=token, method="Network.getResponseBody")
        offset = 0
        chunks = []
        while offset < large["length"]:
            part = await self.command("data", session_id=token, data_id=large["data_id"], offset=offset)
            chunks.append(part["text"])
            offset = part["next_offset"]
        self.assertEqual(json.loads("".join(chunks)), self.reply)
        await self.receive({"method": "Target.dispatchMessageFromTarget", "params": {
            "targetId": "page:1", "message": json.dumps({"method": "Network.loadingFinished", "params": {"requestId": "r"}})}})
        batch = await self.command("events", session_id=token, domain="Network")
        self.assertEqual([e["result"] for e in batch["events"]], [{"requestId": "r"}])
        self.assertEqual((await self.command("events", session_id=token, after=batch["next_cursor"]))["events"], [])
        root = await self.command("send", session_id=token, method="Browser.enable")
        self.assertEqual(root["result"], {"root": True})

    async def test_native_frontend_and_mcp_share_socket_and_route_overlapping_ids(self):
        token = await self.attach()
        self.inspector._event("Console.messageAdded", {"message": {"text": "before panel"}}, "page:1")
        endpoint = await self.command("frontend", page_id="PID:5:1")
        self.assertEqual(endpoint["kind"], "web-page")
        reader, writer = await asyncio.open_unix_connection(endpoint["socket"])
        self.addCleanup(writer.close)

        async def read():
            return json.loads(await asyncio.wait_for(reader.readline(), 2))

        target = (await read())["params"]["targetInfo"]["targetId"]
        history = json.loads((await read())["params"]["message"])
        self.assertEqual(history["params"]["message"]["text"], "before panel")
        self.reply = {"body": "large response" * 2000}
        inner = {"id": 2, "method": "Network.getResponseBody", "params": {"requestId": "r"}}
        outer = {"id": 2, "method": "Target.sendMessageToTarget",
                 "params": {"targetId": target, "message": json.dumps(inner)}}
        writer.write(json.dumps(outer).encode() + b"\n")
        await writer.drain()
        await self.command("send", session_id=token, method="DOM.getDocument")
        self.assertEqual(await read(), {"id": 2, "result": {}})
        reply = json.loads((await read())["params"]["message"])
        self.assertEqual(reply, {"id": 2, "result": self.reply})
        event = {"method": "Console.messageAdded", "params": {"message": {"level": "log", "text": "live"}}}
        await self.receive({"method": "Target.dispatchMessageFromTarget", "params": {
            "targetId": target, "message": json.dumps(event)}})
        self.assertEqual(json.loads((await read())["params"]["message"]), event)
        self.assertEqual((await self.command("logs", session_id=token))["messages"][-1]["text"], "live")
        writer.close()
        await writer.wait_closed()
        async with asyncio.timeout(2):
            while self.inspector.session.frontends:
                await asyncio.sleep(0.01)
        self.service.teardown_inspector_socket.assert_not_awaited()
        self.assertIn("data_id", await self.command("send", session_id=token, method="DOM.getDocument"))
        await self.command("detach", session_id=token)
        self.service.teardown_inspector_socket.assert_awaited_once()
    async def test_chrome_translates_commands_and_releases_only_its_lease(self):
        token = await self.attach()
        endpoint = await self.command("frontend", page_id="PID:5:1", engine="chrome")
        self.assertTrue(endpoint["url"].endswith("/inspector.html"))
        reader, writer = await asyncio.open_unix_connection(endpoint["socket"])
        self.addCleanup(writer.close)
        self.reply = {"result": {"type": "number", "value": 42}}
        request = {"id": 1, "method": "Runtime.evaluate", "params": {"expression": "6*7"}}
        writer.write(json.dumps(request).encode() + b"\n")
        await writer.drain()
        mcp = await self.command("evaluate", session_id=token, expression="6*7")
        response = json.loads(await asyncio.wait_for(reader.readline(), 3))
        self.assertEqual(response["id"], 1)
        self.assertEqual(response["result"]["result"], mcp)
        # This domain is supplied by the CDP translator and does not exist in WebKit.
        writer.write(b'{"id":2,"method":"Storage.getStorageKey","params":{"frameId":"0"}}\n')
        await writer.drain()
        self.assertEqual(json.loads(await asyncio.wait_for(reader.readline(), 3)),
                         {"id": 2, "result": {"storageKey": ""}})
        writer.close()
        await writer.wait_closed()
        async with asyncio.timeout(2):
            while self.inspector.session.frontends:
                await asyncio.sleep(0.01)
        self.service.setup_inspector_socket.assert_awaited_once()
        self.service.teardown_inspector_socket.assert_not_awaited()
        self.assertEqual(await self.command("evaluate", session_id=token, expression="6*7"), mcp)

    async def test_concurrent_cdp_clients_share_the_panel_page(self):
        device = DeviceWebInspector(self.inspector.rsd)
        self.addAsyncCleanup(device.close)
        async def open_client(engine):
            endpoint = await device.command({"action": "frontend", "page_id": "PID:5:1", "engine": engine})
            if engine == "cdp":
                self.assertEqual(set(endpoint), {"socket"})
            reader, writer = await asyncio.open_unix_connection(endpoint["socket"])
            self.addCleanup(writer.close)
            return reader, writer

        panel, official = await asyncio.gather(open_client("chrome"), open_client("cdp"))
        self.assertTrue((await device.command({"action": "list"}))["pages"][0]["attached_here"])
        self.reply = {"result": {"type": "number", "value": 42}}
        for (_, writer), method, params in ((panel, "Runtime.evaluate", {"expression": "42"}),
                                            (official, "Storage.getStorageKey", {"frameId": "0"})):
            writer.write(json.dumps({"id": 1, "method": method, "params": params}).encode() + b"\n")
            await writer.drain()
        replies = [json.loads(line) for line in await asyncio.wait_for(
            asyncio.gather(panel[0].readline(), official[0].readline()), 3)]
        self.assertEqual([r["id"] for r in replies], [1, 1])
        self.assertNotEqual(replies[0]["result"], replies[1]["result"])
        official[1].close()
        await official[1].wait_closed()
        owner = device.pages["PID:5:1"]
        async with asyncio.timeout(3):
            while len(owner.session.frontends) != 1:
                await asyncio.sleep(0.01)
        self.service.setup_inspector_socket.assert_awaited_once()
        self.service.teardown_inspector_socket.assert_not_awaited()
