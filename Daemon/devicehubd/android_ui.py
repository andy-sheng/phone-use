"""Android accessibility snapshots in the shared UITree format."""
import re
import xml.etree.ElementTree as ET

from devicehubd.protocol import RpcError

# A pseudo-terminal streams the hierarchy back without leaving a file on the phone.
DUMP_COMMAND = ("uiautomator", "dump", "/dev/tty")
BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def hierarchy_root(output):
    start, end = output.find("<hierarchy"), output.find("</hierarchy>")
    if start < 0 or end < start:
        return None
    try:
        return ET.fromstring(output[start:end + len("</hierarchy>")])
    except ET.ParseError:
        return None


def ui_tree(output):
    root = hierarchy_root(output)
    if root is None or root.find("node") is None:
        raise RpcError("uiHierarchyUnavailable", "Android returned no readable UI hierarchy. "
                       "Retry when the screen is active and settled, or use screenshot.")

    elements = []
    truncated = False

    def visit(parent, depth, secure=False):
        nonlocal truncated
        for node in parent.iterfind("node"):
            if len(elements) >= 500 or depth >= 32:
                truncated = True
                break
            element = {"type": node.get("class") or "View", "depth": depth}
            if resource := node.get("resource-id"):
                element["id"] = resource
            if (enabled := node.get("enabled")) in ("true", "false"):
                element["enabled"] = enabled == "true"
            password = secure or node.get("password") == "true"
            if not password:
                text = node.get("text")
                label = node.get("content-desc") or text
                if label:
                    element["label"] = label
                if text and text != label:
                    element["value"] = text
            if match := BOUNDS.fullmatch(node.get("bounds", "")):
                x, y, right, bottom = map(int, match.groups())
                if right >= x and bottom >= y:
                    element["frame"] = {"x": x, "y": y, "width": right - x, "height": bottom - y}
            elements.append(element)
            visit(node, depth + 1, password)

    visit(root, 0)
    return {"coordinateSpace": "display-pixels", "elements": elements, "truncated": truncated}
