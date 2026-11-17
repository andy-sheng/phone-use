"""Physical iOS accessibility hierarchy over the existing RSD/DTX transport.

Protocol selectors were cross-checked against sim-use's iOSDeviceBackend (Apache-2.0):
https://github.com/lycorp-jp/sim-use/tree/main/Sources/iOSDeviceBackend
No focus walking: inspector focus traversal can scroll the user's screen.
"""
import asyncio
import contextlib
import json
from typing import Any

from pymobiledevice3.services.accessibilityaudit import AccessibilityAudit
from devicehubd.protocol import RpcError

HIERARCHY_HINT = ("Unlock the device and open a development-signed app with get-task-allow=true. "
                  "System, App Store, TestFlight and distribution-signed apps do not expose this hierarchy. "
                  "Use screenshot and coordinate input for those apps.")


def unwrap(value: Any) -> Any:
    while isinstance(value, dict) and "ObjectType" in value:
        value = value.get("Value")
    return value


def field(value: Any, key: str) -> Any:
    value = unwrap(value)
    return unwrap(value.get(key)) if isinstance(value, dict) else None


def token(value: Any) -> bytes | None:
    candidate = field(value, "PlatformElementValue_v1")
    if isinstance(candidate, bytes) and candidate:
        return candidate
    value = unwrap(value)
    children = value.values() if isinstance(value, dict) else value if isinstance(value, list) else []
    return next((found for child in children if (found := token(child)) is not None), None)


def nodes(value: Any):
    if isinstance(value, dict):
        if value.get("ObjectType") == "AXAuditNode_v1":
            yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def wrapped(kind: str, fields: dict[str, Any]) -> dict[str, Any]:
    return {"ObjectType": kind, "Value": {"ObjectType": "passthrough", "Value": {
        name: {"ObjectType": "passthrough", "Value": value} for name, value in fields.items()
    }}}


def element(handle: bytes) -> dict[str, Any]:
    return wrapped("AXAuditElement_v1", {"PlatformElementValue_v1": handle})


def attribute(name: str, *, action: bool = False) -> dict[str, Any]:
    return wrapped("AXAuditElementAttribute_v1", {
        "AttributeNameValue_v1": name, "HumanReadableNameValue_v1": "Activate" if action else name,
        "DisplayAsTree_v1": 0, "IsInternal_v1": 0, "PerformsActionValue_v1": int(action),
        "SettableValue_v1": 0, "ValueTypeValue_v1": int(action),
    })


def selector_from(raw: Any) -> dict[str, str]:
    try:
        selector = json.loads(raw) if isinstance(raw, str) else raw
    except ValueError:
        selector = None
    if (not isinstance(selector, dict) or set(selector) - {"id", "label", "label_contains", "element_type"}
            or sum(key in selector for key in ("id", "label", "label_contains")) != 1
            or any(not isinstance(value, str) or not value for value in selector.values())):
        raise RpcError("invalidParams", "Specify exactly one non-empty id, label or label_contains; element_type is optional")
    return selector


def matches(row: dict[str, Any], selector: dict[str, str]) -> bool:
    return all((value in (row.get("label") or "") if key == "label_contains" else
                row.get("type" if key == "element_type" else key) == value) for key, value in selector.items())


class IOSUI:
    def __init__(self, audit: AccessibilityAudit, *, limit: int = 500, depth_limit: int = 32):
        self.audit, self.limit, self.depth_limit = audit, limit, depth_limit

    async def prepare(self):
        await self.audit._invoke("deviceInspectorEnable:", True, expects_reply=False)
        await self.audit.set_app_monitoring_enabled(True)
        await self.audit.set_show_visuals(False)

    async def finish(self):
        # Attempt every cleanup even if a preceding send failed. Never disturb the settings channel.
        for name, args in [("deviceInspectorEnable:", (False,)), ("deviceSetAppMonitoringEnabled:", (False,)),
                           ("devicePerformFinalCleanup", ())]:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.audit._invoke(name, *args, expects_reply=False), 0.5)

    async def fetch(self) -> tuple[dict[str, Any], list[bytes]]:
        root = token(await self.audit._invoke("deviceFetchSpecialElement:", 0))
        if root is None:
            raise RpcError("uiHierarchyUnavailable", HIERARCHY_HINT)
        rows, handles, visited = [], [], set()
        truncated = False
        # DFS preserves indentation in the shared text renderer. Never seed with root: the
        # root token can alias the navigation back button, which must remain in the outline.
        async def walk(handle: bytes, depth: int):
            nonlocal truncated
            if depth >= self.depth_limit or len(rows) >= self.limit:
                truncated = True
                return
            reply = await self.audit._invoke("deviceElement:valueForAttribute:", element(handle),
                                             attribute("_AXHierarchyElementsAttribute"))
            for node in nodes(reply):
                child = token(field(node, "AuditElementValue_v1"))
                if child is None:
                    raise RpcError("uiMalformedReply", "Accessibility hierarchy contains an element without a handle")
                summary = field(node, "HumanReadableDescriptionValue_v1") or ""
                role = field(node, "HumanReadableRoleDescriptionValue_v1") or ""
                if not isinstance(summary, str) or not isinstance(role, str):
                    raise RpcError("uiMalformedReply", "Accessibility hierarchy contains invalid labels or roles")
                identity = (child, summary, role)
                if identity in visited:
                    continue
                if len(rows) >= self.limit:
                    truncated = True
                    return
                visited.add(identity)
                label = summary.removesuffix(role).strip(" ,") if role else summary
                # Do not request Value; secure-field summaries are also withheld.
                if "secure" in role.lower() or "password" in role.lower():
                    label = "[secure text field]"
                identifier = field(field(node, "AuditElementValue_v1"), "AccessibilityIdentifier_v1")
                ignored = bool(field(node, "IsIgnoredValue_v1"))
                rows.append({"type": role or "Container", "label": label, "depth": depth,
                             "id": identifier if isinstance(identifier, str) and identifier else None,
                             "enabled": False if ignored or not role else None})
                handles.append(child)
                await walk(child, depth + 1)
        await walk(root, 0)
        if not rows:
            raise RpcError("uiHierarchyUnavailable", HIERARCHY_HINT)
        return {"elements": rows, "truncated": truncated, "coordinateSpace": "unavailable"}, handles

    async def activate(self, selector: dict[str, str], *, text_target: bool = False):
        tree, handles = await self.fetch()
        # A truncated walk cannot prove uniqueness, even if only one observed node matches.
        if tree["truncated"]:
            raise RpcError("uiTreeTruncated", "Cannot resolve a unique target in a truncated tree; use screenshot and coordinate input")
        found = [i for i, row in enumerate(tree["elements"]) if matches(row, selector)]
        if len(found) != 1:
            raise RpcError("uiNoMatch" if not found else "uiAmbiguousMatch",
                           f"{len(found)} elements match. Run describe_ui and refine id/label/element_type")
        row, handle = tree["elements"][found[0]], handles[found[0]]
        if row["enabled"] is False:
            raise RpcError("uiDisabled", "The matching element is ignored or is a non-interactive container")
        if text_target and not any(word in row["type"].lower().replace(" ", "") for word in ("textfield", "textview", "searchfield", "securetext")):
            raise RpcError("invalidParams", "The target must be a text input control")
        traits = unwrap(await self.audit._invoke("deviceElement:valueForAttribute:", element(handle), attribute("Traits")))
        if isinstance(traits, int) and traits & 256:  # UIAccessibilityTraitNotEnabled
            raise RpcError("uiDisabled", "The matching element is disabled")
        try:
            await self.audit._invoke("deviceElement:performAction:withValue:", element(handle),
                                     attribute("AXAction-2010", action=True), 0, expects_reply=False)
        except Exception as error:
            raise RpcError("uiActivationUncertain", "Activation may have been sent; inspect the screen before retrying") from error
