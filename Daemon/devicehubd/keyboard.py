"""Decode bounded batches of USB HID keyboard strokes from the native preview."""

import json

from devicehubd.protocol import RpcError


def preview_keys(payload: str) -> list[tuple[int, bool]]:
    try:
        if not isinstance(payload, str) or len(payload) > 4096:
            raise ValueError
        records = json.loads(payload)
        if not isinstance(records, list) or not 1 <= len(records) <= 32:
            raise ValueError
        keys = []
        for record in records:
            code, shift = record["code"], record["shift"]
            # US letters, digits, punctuation and the supported editing/navigation keys.
            if (type(code) is not int or type(shift) is not bool
                    or not (4 <= code <= 49 or 51 <= code <= 56 or 74 <= code <= 82)):
                raise ValueError
            keys.append((code, shift))
        return keys
    except (ValueError, KeyError, TypeError, RecursionError):
        raise RpcError("invalidParams", "Invalid keyboard input") from None
