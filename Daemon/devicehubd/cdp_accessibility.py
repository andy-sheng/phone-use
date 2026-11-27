"""Expose WebKit accessibility nodes to CDP snapshot and element-handle clients."""

import asyncio
import html
import itertools
from collections import deque

from devicehubd.protocol import RpcError

# Distinct from WebKit frontend node IDs and the translator's frame-owner/description IDs.
_backend_ids = itertools.count(0x40000000)


class AccessibilityTree:
    def __init__(self, session, target):
        self.session = session
        self.target = target
        self.nodes = {}
        self.upstream_resolve = target.from_cdp_special_messages_methods["DOM.resolveNode"]
        target.from_cdp_special_messages_methods.update({
            "Accessibility.getFullAXTree": self.snapshot,
            "DOM.resolveNode": self.resolve,
        })

    async def resolve(self, message):
        backend_id = message["params"].get("backendNodeId")
        if backend_id not in self.nodes:
            await self.upstream_resolve(message)
            return
        try:
            async with asyncio.timeout(5):
                result = await self.session.command("DOM.resolveNode", {"nodeId": self.nodes[backend_id]})
            await self.target.output_queue.put({"id": message["id"], "result": result})
        except (RpcError, TimeoutError):
            await self.target._error_response(message, {"code": -32000, "message": "Element expired. Take a new snapshot."})

    async def snapshot(self, message):
        try:
            async with asyncio.timeout(20):
                nodes = await self._read(message.get("params", {}).get("frameId"))
            await self.target.output_queue.put({"id": message["id"], "result": {"nodes": nodes}})
        except (RpcError, TimeoutError) as error:
            await self.target._error_response(message, {"code": -32000, "message": str(error) or "Snapshot timed out."})

    async def _read(self, frame):
        root = (await self.session.command("DOM.getDocument", {}))["root"]
        if frame and root.get("frameId") and frame != root["frameId"]:
            raise RpcError("unsupportedFrame", "iOS accessibility snapshots require the main frame.")
        root_id = root["nodeId"]
        pending = deque([root_id])
        seen = {root_id}
        result = []
        handles = {}
        while pending:
            batch = [pending.popleft() for _ in range(min(16, len(pending)))]
            rows = await asyncio.gather(*(self._node(n, root_id) for n in batch))
            for node, children in rows:
                result.append(node)
                handles[node["backendDOMNodeId"]] = int(node["nodeId"])
                for child in children:
                    if child not in seen:
                        seen.add(child)
                        pending.append(child)
                if len(seen) > 10000:
                    raise RpcError("snapshotTooLarge", "Page exceeds the 10000-node accessibility snapshot limit.")
        self.nodes = handles
        return result

    async def _node(self, node_id, root_id):
        params = {"nodeId": node_id}
        ax = (await self.session.command("DOM.getAccessibilityPropertiesForNode", params))["properties"]
        role = ax.get("role") or "generic"
        role = "RootWebArea" if node_id == root_id else {"text": "StaticText"}.get(role, role)
        label = ax.get("label", "")
        if role == "StaticText" and not label:
            label = html.unescape((await self.session.command("DOM.getOuterHTML", params))["outerHTML"])
        children = ax.get("childNodeIds", [])
        node = {"nodeId": str(node_id), "backendDOMNodeId": next(_backend_ids),
                "ignored": not ax["exists"] or ax.get("ignored", False),
                "role": {"type": "role", "value": role}, "name": {"type": "computedString", "value": label},
                "childIds": [str(c) for c in children],
                "properties": [{"name": key, "value": {"type": "boolean", "value": ax[key]}}
                               for key in ("disabled", "expanded", "focused", "selected", "required", "readonly")
                               if isinstance(ax.get(key), bool)]}
        return node, children
