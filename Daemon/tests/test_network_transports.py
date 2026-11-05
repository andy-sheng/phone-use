import asyncio
import time
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from pymobiledevice3.exceptions import InvalidServiceError

from devicehubd.protocol import RpcError
from devicehubd.supervisor import DeviceRecord, Supervisor
from devicehubd.transports import Attachment, NetworkDiscovery, UsbDiscovery, _network_tunnel_provider


def device(serial, connection):
    return SimpleNamespace(serial=serial, connection_type=connection, is_usb=connection == "USB")


class NetworkDiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.discovery = NetworkDiscovery()
        self.browse = patch.object(self.discovery, '_browse', new=AsyncMock())
        self.browse.start()

    async def asyncTearDown(self):
        if self.discovery._task:
            self.discovery._task.cancel()
            await asyncio.gather(self.discovery._task, return_exceptions=True)
        self.browse.stop()

    async def test_system_network_device_is_found_without_remote_pairing_records(self):
        with patch('devicehubd.transports.list_devices', new=AsyncMock(return_value=[
                device('friday', 'Network'), device('wired', 'USB')])), \
                patch('devicehubd.transports.wireless_identities', return_value={}):
            self.assertEqual(await self.discovery.attached(), [Attachment('friday', 'network')])
        self.assertTrue(self.discovery.has_system_connection('friday'))
        self.assertFalse(self.discovery.has_system_connection('wired'))

    async def test_system_and_remote_pairing_discovery_merge_without_duplicates(self):
        self.discovery._seen = {'friday': time.monotonic(), 'other': time.monotonic(), 'expired': 0}
        with patch('devicehubd.transports.list_devices', new=AsyncMock(return_value=[device('friday', 'Network')])):
            self.assertEqual(await self.discovery.attached(), [Attachment('friday', 'network'), Attachment('other', 'network')])

    async def test_system_failure_does_not_hide_independently_discovered_peer(self):
        self.discovery._seen['remote'] = time.monotonic()
        self.discovery._system_devices.add('gone')
        with patch('devicehubd.transports.list_devices', new=AsyncMock(side_effect=OSError())):
            self.assertEqual(await self.discovery.attached(), [Attachment('remote', 'network')])
        self.assertFalse(self.discovery.has_system_connection('gone'))

    async def test_system_lockdown_never_attempts_a_new_pairing(self):
        self.discovery._system_devices.add('friday')
        with patch('devicehubd.transports.create_using_usbmux', new=AsyncMock()) as create:
            await self.discovery.lockdown('friday')
            create.assert_awaited_once_with(serial='friday', autopair=False, connection_type='Network')
            with self.assertRaises(RpcError):
                await self.discovery.lockdown('unknown')
        self.assertEqual(create.await_count, 1)

    async def test_usb_still_wins_when_device_is_reachable_over_both_links(self):
        with patch('devicehubd.supervisor._load_cache', return_value={}):
            supervisor = Supervisor()
        supervisor.android.attached = AsyncMock(return_value=[])
        supervisor._schedule_probe = MagicMock()
        supervisor.broadcast = AsyncMock()
        with patch('devicehubd.supervisor.DISCOVERIES', [UsbDiscovery(), self.discovery]), \
                patch('devicehubd.transports.list_devices', new=AsyncMock(return_value=[
                    device('friday', 'Network'), device('friday', 'USB')])):
            await supervisor.poll_devices()
        self.assertEqual(list(supervisor.records), ['friday'])
        self.assertEqual(supervisor.records['friday'].connection, 'usb')


class NetworkTunnelProviderTests(unittest.IsolatedAsyncioTestCase):
    async def test_trusted_system_wifi_uses_coredevice_proxy_without_remote_records(self):
        lockdown = SimpleNamespace(paired=True, close=AsyncMock())
        proxy = MagicMock()
        with patch('devicehubd.transports.list_devices', new=AsyncMock(return_value=[device('friday', 'Network')])), \
                patch('devicehubd.transports.create_using_usbmux', new=AsyncMock(return_value=lockdown)) as create, \
                patch('devicehubd.transports.CoreDeviceTunnelProxy.create', new=AsyncMock(return_value=proxy)), \
                patch('devicehubd.transports.get_remote_pairing_tunnel_services', new=AsyncMock()) as remote:
            self.assertEqual(await _network_tunnel_provider('friday', True, True), (proxy, lockdown))
        create.assert_awaited_once_with(serial='friday', autopair=False, connection_type='Network')
        remote.assert_not_awaited()
        lockdown.close.assert_not_awaited()

    async def test_failed_proxy_open_closes_the_network_lockdown(self):
        lockdown = SimpleNamespace(paired=True, close=AsyncMock())
        with patch('devicehubd.transports.list_devices', new=AsyncMock(return_value=[device('friday', 'Network')])), \
                patch('devicehubd.transports.create_using_usbmux', new=AsyncMock(return_value=lockdown)), \
                patch('devicehubd.transports.CoreDeviceTunnelProxy.create', new=AsyncMock(side_effect=OSError())):
            with self.assertRaises(OSError):
                await _network_tunnel_provider('friday', False, True)
        lockdown.close.assert_awaited_once()

    async def test_untrusted_system_device_is_not_marked_authenticated_or_paired(self):
        lockdown = SimpleNamespace(paired=False, close=AsyncMock())
        with patch('devicehubd.transports.list_devices', new=AsyncMock(return_value=[device('friday', 'Network')])), \
                patch('devicehubd.transports.create_using_usbmux', new=AsyncMock(return_value=lockdown)), \
                patch('devicehubd.transports.CoreDeviceTunnelProxy.create', new=AsyncMock()) as proxy:
            with self.assertRaises(RpcError) as caught:
                await _network_tunnel_provider('friday', True, True)
        self.assertEqual(caught.exception.code, 'notReady')
        proxy.assert_not_awaited()
        lockdown.close.assert_awaited_once()

    async def test_older_system_without_proxy_preserves_remote_pairing_fallback(self):
        lockdown = SimpleNamespace(paired=True, close=AsyncMock())
        remote = SimpleNamespace(close=AsyncMock())
        with patch('devicehubd.transports.list_devices', new=AsyncMock(return_value=[device('older', 'Network')])), \
                patch('devicehubd.transports.create_using_usbmux', new=AsyncMock(return_value=lockdown)), \
                patch('devicehubd.transports.CoreDeviceTunnelProxy.create', new=AsyncMock(side_effect=InvalidServiceError('Service unavailable', 'older', '17.3'))), \
                patch('devicehubd.transports.get_remote_pairing_tunnel_services', new=AsyncMock(return_value=[remote])):
            self.assertEqual(await _network_tunnel_provider('older', False, True), (remote, None))
        lockdown.close.assert_awaited_once()
        remote.close.assert_not_awaited()

    async def test_remote_pairing_path_survives_usbmux_failure_and_closes_extra_answers(self):
        first, extra = SimpleNamespace(close=AsyncMock()), SimpleNamespace(close=AsyncMock())
        with patch('devicehubd.transports.list_devices', new=AsyncMock(side_effect=OSError())), \
                patch('devicehubd.transports.get_remote_pairing_tunnel_services', new=AsyncMock(return_value=[first, extra])):
            self.assertEqual(await _network_tunnel_provider('remote', False, True), (first, None))
        first.close.assert_not_awaited()
        extra.close.assert_awaited_once()


class SystemNetworkProbeTests(unittest.IsolatedAsyncioTestCase):
    async def test_network_probe_reads_real_name_and_version_without_pairing_again(self):
        with patch('devicehubd.supervisor._load_cache', return_value={}):
            supervisor = Supervisor()
        supervisor.broadcast = AsyncMock()
        supervisor._ensure_wireless = AsyncMock()
        supervisor.records['friday'] = DeviceRecord('friday', 'network')
        lockdown = SimpleNamespace(
            paired=True, close=AsyncMock(),
            all_values={'DeviceName': 'Friday', 'ProductType': 'iPhone18,1', 'ProductVersion': '27.2'},
        )
        discovery = SimpleNamespace(has_system_connection=lambda _: True, lockdown=AsyncMock(return_value=lockdown))
        mounter = MagicMock()
        mounter.__aenter__ = AsyncMock(return_value=SimpleNamespace(query_developer_mode_status=AsyncMock(return_value=True)))
        mounter.__aexit__ = AsyncMock()
        with patch('devicehubd.supervisor.discovery_for', return_value=discovery), \
                patch('devicehubd.supervisor.MobileImageMounterService', return_value=mounter), \
                patch('devicehubd.supervisor._save_cache'):
            await supervisor.probe('friday')
        record = supervisor.records['friday']
        self.assertEqual((record.name, record.product_version, record.state), ('Friday', '27.2', 'ready'))
        self.assertTrue(record.wireless)
        supervisor._ensure_wireless.assert_not_awaited()
        lockdown.close.assert_awaited_once()
