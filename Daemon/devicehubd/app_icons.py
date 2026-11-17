"""Small, session-local cache of application icons returned by SpringBoard."""

import asyncio
import base64
from collections import OrderedDict

from pymobiledevice3.services.springboard import SpringBoardServicesService

from devicehubd.protocol import RpcError


class AppIcons:
    def __init__(self, rsd):
        self.rsd = rsd
        self.lock = asyncio.Lock()
        self.cache = OrderedDict()

    async def get(self, bundle_id: str, version: str = "") -> dict:
        if not isinstance(bundle_id, str) or not bundle_id or len(bundle_id) > 512 or "\0" in bundle_id:
            raise RpcError("invalidParams", "An app bundle identifier is required")
        if not isinstance(version, str) or len(version) > 256:
            raise RpcError("invalidParams", "Invalid app version")
        key = (bundle_id, version)
        async with self.lock:
            if key in self.cache:
                self.cache.move_to_end(key)
                return {"png": self.cache[key]}
            # Serialize requests so scrolling a list cannot open dozens of device services.
            # Unsupported/locked apps simply use the UI placeholder; retries happen on refresh.
            try:
                async with asyncio.timeout(5):
                    async with SpringBoardServicesService(self.rsd) as service:
                        data = await service.get_icon_pngdata(bundle_id)
            except Exception:
                return {"png": None}
            if not isinstance(data, bytes) or not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) > 512 * 1024:
                return {"png": None}
            encoded = base64.b64encode(data).decode("ascii")
            self.cache[key] = encoded
            if len(self.cache) > 128:
                self.cache.popitem(last=False)
            return {"png": encoded}
