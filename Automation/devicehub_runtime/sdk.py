"""Small, versioned contract implemented by an external plugin.

Plugins are trusted Python code, loaded only in a host-owned worker process.
The host owns the controller, resource, tasker, cancellation and output channel.
"""

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable


@dataclass
class RuntimeContext:
    resource: Any
    stop: Any
    emit: Callable
    plugin_root: Path
    assets: Path
    output: Path

    def path(self, relative: str) -> Path:
        path = (self.plugin_root / relative).resolve()
        if not path.is_relative_to(self.plugin_root.resolve()):
            raise ValueError("Plugin resource path is outside its package")
        return path


@dataclass
class PreparedTask:
    entry: str
    bundles: list[Path] = field(default_factory=list)
    pipeline: dict = field(default_factory=dict)
    timeout: float = 180
    # Custom actions may extend their deadline for retries or explicit waits.
    deadline: Callable[[], float] | None = None
    result: Callable[[bool], dict] | None = None
    references: list[Any] = field(default_factory=list)


def validate_config(parameters: list[dict], supplied: dict) -> dict:
    if not isinstance(supplied, dict):
        raise ValueError("任务配置必须是 JSON 对象")
    known = {item["key"] for item in parameters}
    if set(supplied) - known:
        raise ValueError("未知任务参数：" + ", ".join(sorted(set(supplied) - known)))
    result = {}
    for item in parameters:
        key, kind = item["key"], item["type"]
        value = supplied.get(key, item.get("default"))
        if kind == "integer":
            valid = isinstance(value, int) and not isinstance(value, bool)
            valid = valid and item.get("min", value) <= value <= item.get("max", value)
        elif kind == "boolean":
            valid = isinstance(value, bool)
        elif kind == "string":
            valid = isinstance(value, str) and len(value) <= 4000
        elif kind == "choice":
            valid = isinstance(value, str) and value in {choice["value"] for choice in item["choices"]}
        else:
            valid = False
        if not valid:
            raise ValueError(f"任务参数不符合要求：{item.get('title', key)}")
        result[key] = value
    return result
