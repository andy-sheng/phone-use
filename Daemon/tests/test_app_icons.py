import base64
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

from devicehubd.app_icons import AppIcons
from devicehubd.protocol import RpcError


class AppIconTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.service = MagicMock()
        self.service.__aenter__ = AsyncMock(return_value=self.service)
        self.service.__aexit__ = AsyncMock(return_value=False)
        self.png = b"\x89PNG\r\n\x1a\nicon"
        self.service.get_icon_pngdata = AsyncMock(return_value=self.png)
        self.factory = patch("devicehubd.app_icons.SpringBoardServicesService", return_value=self.service)
        self.factory.start()
        self.addCleanup(self.factory.stop)
        self.icons = AppIcons(object())

    async def test_caches_by_bundle_and_version_and_closes_service(self):
        self.assertEqual(await self.icons.get("app", "1"), {"png": base64.b64encode(self.png).decode()})
        await self.icons.get("app", "1")
        self.service.get_icon_pngdata.assert_awaited_once_with("app")
        self.service.__aexit__.assert_awaited_once()
        await self.icons.get("app", "2")
        self.assertEqual(self.service.get_icon_pngdata.await_count, 2)

    async def test_missing_invalid_and_oversized_icons_fall_back(self):
        for payload in [None, b"not png", b"\x89PNG\r\n\x1a\n" + b"x" * 524288]:
            self.service.get_icon_pngdata.return_value = payload
            self.assertEqual(await self.icons.get("app"), {"png": None})
        self.assertFalse(self.icons.cache)

    async def test_device_failure_falls_back_and_can_retry(self):
        self.service.get_icon_pngdata.side_effect = RuntimeError("device unavailable")
        self.assertEqual(await self.icons.get("app"), {"png": None})
        self.service.__aexit__.assert_awaited_once()
        self.service.get_icon_pngdata.side_effect = None
        self.assertIsNotNone((await self.icons.get("app"))["png"])

    async def test_invalid_identifier_never_opens_device_service(self):
        for bundle in [None, "", "a\0", "a" * 513]:
            with self.assertRaises(RpcError):
                await self.icons.get(bundle)
        self.service.__aenter__.assert_not_awaited()
