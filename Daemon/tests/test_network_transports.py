import asyncio
import time
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from pymobiledevice3.exceptions import InvalidServiceError

from devicehubd.protocol import RpcError
from devicehubd.supervisor import DeviceRecord, Supervisor
from devicehubd import transports
from devicehubd.transports import ENDPOINTS_ENV, NETWORK_TTL, REACHABILITY_AFTER, SYSTEM_NETWORK_TTL, Attachment, NetworkDiscovery, UsbDiscovery, _network_tunnel_provider, _remote_pairing_service


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

    async def test_system_device_survives_a_short_usbmux_gap_but_not_a_long_one(self):
        listing = AsyncMock(return_value=[device('friday', 'Network')])
        with patch('devicehubd.transports.list_devices', new=listing):
            self.assertEqual(await self.discovery.attached(), [Attachment('friday', 'network')])
            listing.return_value = []
            self.assertEqual(await self.discovery.attached(), [Attachment('friday', 'network')])
            # Opening lockdown still needs the live usbmuxd listing.
            self.assertFalse(self.discovery.has_system_connection('friday'))
            with patch('devicehubd.transports.time.monotonic', return_value=time.monotonic() + NETWORK_TTL + 1):
                self.assertEqual(await self.discovery.attached(), [Attachment('friday', 'network')])
            with patch('devicehubd.transports.time.monotonic', return_value=time.monotonic() + SYSTEM_NETWORK_TTL + 1):
                self.assertEqual(await self.discovery.attached(), [])

    async def test_browse_matches_system_bonjour_answers_and_remembers_their_addresses(self):
        self.browse.stop()
        calls = []

        async def iter_browse(service_type, timeout, addresses=True):
            calls.append((service_type, addresses))
            yield answer('mine', '192.168.1.5', 'fe80::1%en1')
            self.discovery._task.cancel()

        with patch('devicehubd.transports.system_bonjour.iter_browse', iter_browse), \
                patch('devicehubd.transports.wireless_identities', return_value={'udid': b'irk'}), \
                patch('devicehubd.transports._match_remote_pair_record', return_value='udid'), \
                patch('devicehubd.transports.list_devices', new=AsyncMock(return_value=[])):
            await self.discovery.attached()
            await asyncio.gather(self.discovery._task, return_exceptions=True)
            self.assertEqual(await self.discovery.attached(), [Attachment('udid', 'network')])
        self.discovery._task = None
        self.browse.start()
        self.assertEqual(calls, [('_remotepairing._tcp.local.', True)])
        self.assertEqual(self.discovery.endpoints('udid'), [('192.168.1.5', 49152), ('fe80::1%en1', 49152)])

    async def test_quiet_peer_stays_while_its_last_address_accepts_connections(self):
        now = time.monotonic()
        self.discovery._endpoints = {'asleep': [('192.168.1.5', 49152)], 'gone': [('192.168.1.6', 49152)],
                                     'expired': [('192.168.1.7', 49152)], 'fresh': [('192.168.1.8', 49152)]}
        self.discovery._seen = {'asleep': now - REACHABILITY_AFTER - 1, 'gone': now - REACHABILITY_AFTER - 1,
                                'expired': now - NETWORK_TTL - 1, 'fresh': now}
        reachable = AsyncMock(side_effect=lambda endpoints: endpoints[0][0] == '192.168.1.5')
        with patch('devicehubd.transports._reachable', reachable):
            await self.discovery._check_quiet_peers({'asleep', 'gone', 'expired', 'fresh'})
        # Only peers inside their grace period that have been quiet for a while are checked.
        self.assertEqual(sorted(call.args[0][0][0] for call in reachable.await_args_list), ['192.168.1.5', '192.168.1.6'])
        self.assertGreater(self.discovery._seen['asleep'], now)
        self.assertLess(self.discovery._seen['gone'], now)

    async def test_reachability_is_a_plain_tcp_connect(self):
        server = await asyncio.start_server(lambda reader, writer: writer.close(), '127.0.0.1', 0)
        port = server.sockets[0].getsockname()[1]
        async with server:
            self.assertTrue(await transports._reachable([('127.0.0.1', 1), ('127.0.0.1', port)]))
        self.assertFalse(await transports._reachable([('127.0.0.1', port)]))

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
        supervisor.simulators.attached = AsyncMock(return_value=[])
        supervisor._schedule_probe = MagicMock()
        supervisor.broadcast = AsyncMock()
        with patch('devicehubd.supervisor.DISCOVERIES', [UsbDiscovery(), self.discovery]), \
                patch('devicehubd.transports.list_devices', new=AsyncMock(return_value=[
                    device('friday', 'Network'), device('friday', 'USB')])):
            await supervisor.poll_devices()
        self.assertEqual(list(supervisor.records), ['friday'])
        self.assertEqual(supervisor.records['friday'].connection, 'usb')

    async def test_open_wifi_session_is_not_detached_by_a_discovery_gap(self):
        with patch('devicehubd.supervisor._load_cache', return_value={}):
            supervisor = Supervisor()
        supervisor.android.attached = AsyncMock(return_value=[])
        supervisor.simulators.attached = AsyncMock(return_value=[])
        supervisor._schedule_probe = MagicMock()
        supervisor.broadcast = AsyncMock()
        record = DeviceRecord('friday', 'network', paired=True, developer_mode=True, developer_image=True, session='open')
        supervisor.records['friday'] = record
        worker = MagicMock(stopping=False, process=SimpleNamespace(returncode=None))
        supervisor.workers['friday'] = worker
        empty = SimpleNamespace(connection='network', attached=AsyncMock(return_value=[]))
        with patch('devicehubd.supervisor.DISCOVERIES', [empty]):
            await supervisor.poll_devices()
            self.assertIs(supervisor.records['friday'], record)
            self.assertEqual((record.state, record.session), ('ready', 'open'))
            worker.stop.assert_not_called()
            # Once the worker has exited, the missing listing detaches the device as before.
            worker.process.returncode = 1
            await supervisor.poll_devices()
        self.assertEqual(record.state, 'disconnected')


class NetworkTunnelProviderTests(unittest.IsolatedAsyncioTestCase):
    async def test_trusted_system_wifi_uses_coredevice_proxy_without_remote_records(self):
        lockdown = SimpleNamespace(paired=True, close=AsyncMock())
        proxy = MagicMock()
        with patch('devicehubd.transports.list_devices', new=AsyncMock(return_value=[device('friday', 'Network')])), \
                patch('devicehubd.transports.create_using_usbmux', new=AsyncMock(return_value=lockdown)) as create, \
                patch('devicehubd.transports.CoreDeviceTunnelProxy.create', new=AsyncMock(return_value=proxy)), \
                patch('devicehubd.transports._remote_pairing_service', new=AsyncMock()) as remote:
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
                patch('devicehubd.transports._remote_pairing_service', new=AsyncMock(return_value=remote)):
            self.assertEqual(await _network_tunnel_provider('older', False, True), (remote, None))
        lockdown.close.assert_awaited_once()
        remote.close.assert_not_awaited()

    async def test_remote_pairing_path_survives_usbmux_failure(self):
        remote = SimpleNamespace(close=AsyncMock())
        with patch('devicehubd.transports.list_devices', new=AsyncMock(side_effect=OSError())), \
                patch('devicehubd.transports._remote_pairing_service', new=AsyncMock(return_value=remote)) as connect:
            self.assertEqual(await _network_tunnel_provider('remote', False, True), (remote, None))
        connect.assert_awaited_once_with('remote')


def answer(identifier, *addresses):
    return SimpleNamespace(properties={'identifier': identifier}, port=49152,
                           addresses=[SimpleNamespace(full_ip=address) for address in addresses])


class RemotePairingServiceTests(unittest.IsolatedAsyncioTestCase):
    def browse(self, *answers):
        calls = []

        async def iter_browse(service_type, timeout, addresses=True):
            calls.append((service_type, addresses))
            for item in answers:
                yield item
        return calls, patch('devicehubd.transports.system_bonjour.iter_browse', iter_browse)

    async def test_skips_other_devices_and_falls_through_unreachable_addresses(self):
        service = object()
        calls, browse = self.browse(answer('other', '10.0.0.9'), answer('mine', 'fe80::1%en1', '192.168.1.5'))
        connect = AsyncMock(side_effect=[OSError('no route'), service])
        with browse, patch('devicehubd.transports.wireless_identities', return_value={'udid': b'irk'}), \
                patch('devicehubd.transports._match_remote_pair_record',
                      side_effect=lambda item, irks: 'udid' if item.properties['identifier'] == 'mine' else None), \
                patch('devicehubd.transports._open_remote_pairing', connect):
            self.assertIs(await _remote_pairing_service('udid'), service)
        self.assertEqual([call.args for call in connect.await_args_list],
                         [('udid', 'fe80::1%en1', 49152), ('udid', '192.168.1.5', 49152)])
        self.assertEqual(calls, [('_remotepairing._tcp.local.', True)])

    async def test_last_advertised_address_is_tried_before_browsing(self):
        service = object()
        calls, browse = self.browse()
        connect = AsyncMock(return_value=service)
        with browse, patch.dict('os.environ', {ENDPOINTS_ENV: '[["192.168.1.111", 49152]]'}), \
                patch('devicehubd.transports.wireless_identities', return_value={'udid': b'irk'}), \
                patch('devicehubd.transports._open_remote_pairing', connect):
            self.assertIs(await _remote_pairing_service('udid'), service)
        connect.assert_awaited_once_with('udid', '192.168.1.111', 49152)
        self.assertEqual(calls, [])

    async def test_stale_address_falls_back_to_a_browse_without_retrying_it(self):
        service = object()
        _, browse = self.browse(answer('mine', '192.168.1.111', '192.168.1.120'))
        connect = AsyncMock(side_effect=[OSError('stale'), service])
        with browse, patch.dict('os.environ', {ENDPOINTS_ENV: '[["192.168.1.111", 49152]]'}), \
                patch('devicehubd.transports.wireless_identities', return_value={'udid': b'irk'}), \
                patch('devicehubd.transports._match_remote_pair_record', return_value='udid'), \
                patch('devicehubd.transports._open_remote_pairing', connect):
            self.assertIs(await _remote_pairing_service('udid'), service)
        self.assertEqual([call.args[1] for call in connect.await_args_list], ['192.168.1.111', '192.168.1.120'])

    async def test_without_a_wifi_record_does_not_browse(self):
        calls, browse = self.browse()
        with browse, patch('devicehubd.transports.wireless_identities', return_value={}):
            with self.assertRaises(ConnectionError):
                await _remote_pairing_service('udid')
        self.assertEqual(calls, [])

    async def test_no_matching_answer_is_a_connection_error(self):
        _, browse = self.browse(answer('other', '10.0.0.9'))
        with browse, patch('devicehubd.transports.wireless_identities', return_value={'udid': b'irk'}), \
                patch('devicehubd.transports._match_remote_pair_record', return_value=None):
            with self.assertRaises(ConnectionError):
                await _remote_pairing_service('udid')


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
