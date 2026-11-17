"""Bounded, single-delivery text input through a temporary universal HID keyboard."""
import asyncio
import contextlib
import secrets

from pymobiledevice3.remote.core_device.hid_service import ASCII_TO_HID, KEY_LEFT_SHIFT, UniversalHIDServiceService
from devicehubd.protocol import RpcError


def text_keys(text):
    if not isinstance(text, str) or not text or len(text) > 500:
        raise RpcError("invalidParams", "Physical iOS type_text accepts 1–500 US keyboard characters per call")
    if any(char not in ASCII_TO_HID for char in text):
        raise RpcError("invalidParams", "Unsupported text: use US keyboard characters or the on-screen input method. No input was sent")
    return [ASCII_TO_HID[char] for char in text]


async def type_keys(rsd, keys):
    keyboard = UniversalHIDServiceService(rsd)
    service_id = None
    try:
        await keyboard.connect()
        # Independent app workers must not overwrite one another's keyboard surface.
        service_id = await keyboard.create_keyboard_service(service_id=(1 << 63) | secrets.randbits(48))
        for code, shifted in keys:
            await keyboard.send_keyboard(service_id, [KEY_LEFT_SHIFT, code] if shifted else [code])
            await asyncio.sleep(0.01)
            await keyboard.send_keyboard(service_id, [])
            await asyncio.sleep(0.01)
    except (Exception, asyncio.CancelledError) as error:
        raise RpcError("textInputUncertain", "Text input may be partial. Inspect the field before retrying; input was not replayed") from error
    finally:
        if service_id is not None:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(keyboard.send_keyboard(service_id, []), 1)
        with contextlib.suppress(Exception):
            await asyncio.wait_for(keyboard.close(), 1)
