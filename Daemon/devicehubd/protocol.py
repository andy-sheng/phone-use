"""Newline-delimited JSON framing shared by the client socket and the worker pipes.

Requests are ``{"id", "method", "params"}``, replies ``{"id", "result"}`` or
``{"id", "error": {"code", "message"}}``, and notifications ``{"method", "params"}``.
"""

import json
from typing import Any


class RpcError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message

    def to_json(self) -> dict[str, str]:
        return {"code": self.code, "message": self.message}


def encode(message: dict[str, Any]) -> bytes:
    return json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"


def decode(line: bytes) -> dict[str, Any]:
    message = json.loads(line)
    if not isinstance(message, dict):
        raise ValueError("message is not an object")
    return message
