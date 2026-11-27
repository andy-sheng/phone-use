"""Exercise both tool providers on the packaged stdio entry point without Node on PATH."""

import asyncio
import json
from pathlib import Path
import shutil
import sys
import tempfile


async def native(reader, writer):
    try:
        while line := await reader.readline():
            request = json.loads(line)
            assert request["params"]["name"] in {"list_devices", "list_apps"}
            reply = {"jsonrpc": "2.0", "id": request["id"], "result": {"content": [{"type": "text", "text": "native"}]}}
            writer.write(json.dumps(reply).encode() + b"\n")
            await writer.drain()
    finally:
        writer.close()


async def check(executable, directory, full):
    path = "/usr/bin:/bin:/usr/sbin:/sbin"
    assert all(shutil.which(tool, path=path) is None for tool in ("node", "npx", "npm"))
    env = {"PATH": path, "HOME": directory, "TMPDIR": directory, "DEVICEHUB_SOCKET": directory + "/unused",
           "DEVICEHUB_MCP_SOCKET": directory + "/native.sock"}
    async with await asyncio.start_unix_server(native, env["DEVICEHUB_MCP_SOCKET"]):
        server = await asyncio.create_subprocess_exec(executable, *(["--all-tools"] if full else []), env=env, stdin=-1, stdout=-1, limit=2 << 20)
        async def send(method, params, req_id=None):
            msg = {"jsonrpc": "2.0", "method": method, "params": params}
            if req_id is not None:
                msg["id"] = req_id
            server.stdin.write(json.dumps(msg).encode() + b"\n")
            await server.stdin.drain()

        async def reply():
            async with asyncio.timeout(20):
                while line := await server.stdout.readline():
                    msg = json.loads(line)
                    if "id" in msg:
                        return msg
            raise EOFError("Unexpected end of MCP stream")

        try:
            await send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "bundle-test", "version": "1"}}, 1)
            assert (await reply())["result"]["serverInfo"]["name"] == "phone-use"
            await send("notifications/initialized", {})
            await send("tools/list", {}, 2)
            tools = [t["name"] for t in (await reply())["result"]["tools"]]
            assert len(set(tools)) == len(tools)
            async def search(args):
                await send("tools/call", {"name": "search_tools", "arguments": args}, "search")
                return json.loads((await reply())["result"]["content"][0]["text"])

            if full:
                assert {"type_text", "list_devices", "chrome_type_text", "chrome_evaluate_script"} <= set(tools)
                assert "run_tool" not in tools
            else:
                assert set(tools) == {"list_devices", "select_device", "connect_device", "describe_ui",
                                      "screenshot", "search_tools", "run_tool"}
                counts = (await search({}))["groups"]
                assert counts["chrome"] == 32
                first = await search({"group": "chrome"})
                second = await search({"group": "chrome", "offset": first["next_offset"]})
                assert len(first["matches"]) == 8 and first["total"] == counts["chrome"]
                assert first["matches"][0] != second["matches"][0]
                assert all("inputSchema" not in item for item in first["matches"])
                schema = (await search({"query": "chrome_evaluate_script"}))["tool"]
                assert "function" in schema["inputSchema"]["properties"]
                assert (await search({"query": "nonexistent_operation"}))["total"] == 0
                await send("tools/call", {"name": "run_tool", "arguments": {"name": "run_tool", "arguments": {}}}, 3)
                assert (await reply())["result"]["isError"]

            async def invoke(name, request_id):
                params = {"name": name, "arguments": {}}
                if not full:
                    params = {"name": "run_tool", "arguments": params}
                await send("tools/call", params, request_id)

            await invoke("chrome_evaluate_script", "web")
            await invoke("list_apps", "phone")
            results = {}
            for _ in range(2):
                msg = await reply()
                results[msg["id"]] = msg["result"]
            assert results["phone"]["content"][0]["text"] == "native"
            assert results["web"]["isError"] and "pageId" in results["web"]["content"][0]["text"]
        finally:
            server.stdin.close()
            await asyncio.wait_for(server.wait(), 10)
        assert server.returncode == 0


if __name__ == "__main__":
    app = Path(sys.argv[1] if len(sys.argv) > 1 else "dist/PhoneUse.app").resolve()
    with tempfile.TemporaryDirectory(dir="/tmp") as directory:
        for full in (False, True):
            asyncio.run(check(app / "Contents/Helpers/phone-use-mcp", directory, full))
    print("Bundled native and Chrome tool routing passed")
