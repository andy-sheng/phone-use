import asyncio
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

from devicehubd.ios_ui import IOSUI, attribute, element, field, selector_from, token, wrapped
from devicehubd.ios_keyboard import text_keys, type_keys
from devicehubd.protocol import RpcError
from devicehubd.worker import Worker
from devicehubd.supervisor import Supervisor, WORKER_UI_METHODS


def node(handle, label="Save", role="Button", identifier=None, ignored=False):
    data = element(handle)
    data["Value"]["Value"]["AccessibilityIdentifier_v1"] = {"ObjectType": "passthrough", "Value": identifier}
    return wrapped("AXAuditNode_v1", {"AuditElementValue_v1": data,
                   "HumanReadableDescriptionValue_v1": label + " " + role,
                   "HumanReadableRoleDescriptionValue_v1": role, "IsIgnoredValue_v1": ignored})


class FakeAudit:
    def __init__(self, tree):
        self.tree, self.calls = tree, []

    async def _invoke(self, name, *args, **kwargs):
        self.calls.append((name, args, kwargs))
        if name == "deviceFetchSpecialElement:":
            return element(b"root")
        if name == "deviceElement:valueForAttribute:":
            if field(args[1], "AttributeNameValue_v1") == "Traits":
                return 0
            return self.tree.get(token(args[0]), [])

    async def set_app_monitoring_enabled(self, value):
        pass

    async def set_show_visuals(self, value):
        pass


class HierarchyTests(unittest.IsolatedAsyncioTestCase):
    async def test_nested_tree_keeps_root_alias_and_never_moves_focus_or_fabricates_geometry(self):
        audit = FakeAudit({b"root": [node(b"root", "Back", identifier="BackButton"), node(b"field", "Password", "SecureTextField")],
                           b"field": [node(b"child", "Nested")]})
        tree, handles = await IOSUI(audit).fetch()
        self.assertEqual(len(tree["elements"]), 3)
        self.assertEqual(tree["elements"][0]["id"], "BackButton")
        self.assertEqual(tree["elements"][1]["label"], "[secure text field]")
        self.assertEqual(tree["coordinateSpace"], "unavailable")
        self.assertNotIn("frame", tree["elements"][0])
        self.assertNotIn("value", tree["elements"][1])
        self.assertIsNone(tree["elements"][0]["enabled"])
        self.assertFalse(tree["truncated"])
        self.assertFalse(any("Move" in name for name, _, _ in audit.calls))

    async def test_activate_uses_live_token_correctly_nested_and_single_delivery(self):
        audit = FakeAudit({b"root": [node(b"save", identifier="save")]})
        await IOSUI(audit).activate({"id": "save"})
        name, args, kwargs = audit.calls[-1]
        self.assertEqual(name, "deviceElement:performAction:withValue:")
        self.assertEqual(args[0]["Value"]["Value"]["PlatformElementValue_v1"]["Value"], b"save")
        self.assertEqual(field(args[1], "AttributeNameValue_v1"), "AXAction-2010")
        self.assertFalse(kwargs["expects_reply"])
        self.assertEqual(sum(name == "deviceFetchSpecialElement:" for name, _, _ in audit.calls), 1)

    async def test_missing_ambiguous_ignored_truncated_and_non_text_targets_never_activate(self):
        for children, selector, limit, text in [
            ([node(b"a")], {"id": "missing"}, 500, False),
            ([node(b"a"), node(b"b")], {"label": "Save"}, 500, False),
            ([node(b"a", ignored=True)], {"label": "Save"}, 500, False),
            ([node(b"a"), node(b"b", "Other")], {"label": "Save"}, 1, False),
            ([node(b"a")], {"label": "Save"}, 500, True),
        ]:
            audit = FakeAudit({b"root": children})
            with self.assertRaises(RpcError):
                await IOSUI(audit, limit=limit).activate(selector, text_target=text)
            self.assertFalse(any("performAction" in name for name, _, _ in audit.calls))

    async def test_disabled_traits_refuse_activation(self):
        audit = FakeAudit({b"root": [node(b"a")]})
        invoke = audit._invoke
        async def disabled(name, *args, **kwargs):
            if name == "deviceElement:valueForAttribute:" and field(args[1], "AttributeNameValue_v1") == "Traits":
                return {"ObjectType": "passthrough", "Value": 256}
            return await invoke(name, *args, **kwargs)
        audit._invoke = disabled
        with self.assertRaisesRegex(RpcError, "disabled"):
            await IOSUI(audit).activate({"label": "Save"})
        self.assertFalse(any("performAction" in name for name, _, _ in audit.calls))

    async def test_empty_or_locked_hierarchy_is_a_capability_error(self):
        audit = FakeAudit({})
        with self.assertRaisesRegex(RpcError, "get-task-allow"):
            await IOSUI(audit).fetch()
        audit._invoke = AsyncMock(return_value=None)
        with self.assertRaisesRegex(RpcError, "get-task-allow"):
            await IOSUI(audit).fetch()

    async def test_transport_failure_does_not_replay_activation(self):
        audit = FakeAudit({b"root": [node(b"a")]})
        invoke = audit._invoke
        async def failed(name, *args, **kwargs):
            if "performAction" in name:
                audit.calls.append((name, args, kwargs))
                raise ConnectionError("dropped")
            return await invoke(name, *args, **kwargs)
        audit._invoke = failed
        with self.assertRaisesRegex(RpcError, "may have been sent"):
            await IOSUI(audit).activate({"label": "Save"})
        self.assertEqual(sum("performAction" in name for name, _, _ in audit.calls), 1)

    def test_selector_validation(self):
        for value in [None, {}, {"label": ""}, {"id": "a", "label": "b"}, {"label": 1}, {"label": "a", "unknown": "b"}, "bad"]:
            with self.assertRaises(RpcError):
                selector_from(value)
        self.assertEqual(selector_from('{"id":"save"}'), {"id": "save"})

    async def test_cleanup_attempts_all_selectors_after_failure(self):
        audit = MagicMock()
        audit._invoke = AsyncMock(side_effect=[ConnectionError(), None, None])
        await IOSUI(audit).finish()
        self.assertEqual(audit._invoke.await_count, 3)


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    def worker(self):
        worker = Worker.__new__(Worker)
        worker._rsd = MagicMock(product_version="27.0")
        worker._audit_lock = asyncio.Lock()
        worker.start_mirror = AsyncMock()
        return worker

    async def test_worker_closes_inspector_on_failure_without_touching_settings_channel(self):
        worker = self.worker()
        worker._audit = sentinel = object()
        audit = MagicMock()
        audit.__aenter__ = AsyncMock()
        audit.close = AsyncMock()
        inspector = MagicMock()
        inspector.prepare = AsyncMock()
        inspector.fetch = AsyncMock(side_effect=RpcError("uiHierarchyUnavailable", "locked"))
        inspector.finish = AsyncMock()
        with patch("devicehubd.worker.AccessibilityAudit", return_value=audit), patch("devicehubd.worker.IOSUI", return_value=inspector):
            with self.assertRaises(RpcError):
                await worker.ui_command("describeUI", {})
        inspector.finish.assert_awaited_once()
        audit.close.assert_awaited_once()
        self.assertIs(worker._audit, sentinel)
        self.assertFalse(worker._audit_lock.locked())

    async def test_cancelled_lock_wait_cannot_later_activate(self):
        worker = self.worker()
        await worker._audit_lock.acquire()
        with patch("devicehubd.worker.AccessibilityAudit") as factory:
            task = asyncio.create_task(worker.ui_command("activateUI", {"selector": '{"id":"save"}'}))
            await asyncio.sleep(0)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            worker._audit_lock.release()
            factory.assert_not_called()

    async def test_invalid_or_unsupported_text_rejects_before_focus_or_mirror(self):
        worker = self.worker()
        with patch("devicehubd.worker.AccessibilityAudit") as factory:
            for text in ["a中文", "a" * 501, ""]:
                with self.assertRaises(RpcError):
                    await worker.ui_command("typeText", {"text": text, "selector": '{"id":"field"}'})
            worker._rsd.product_version = "18.6"
            with self.assertRaisesRegex(RpcError, "iOS 27"):
                await worker.ui_command("typeText", {"text": "hello"})
            factory.assert_not_called()
            worker.start_mirror.assert_not_awaited()

    async def test_preview_keyboard_bypasses_inspector_and_validates_entire_batch(self):
        worker = self.worker()
        worker._mirror_started = 0
        with patch("devicehubd.worker.AccessibilityAudit") as audit, patch("devicehubd.worker.type_keys") as send:
            await worker.ui_command("keyboardInput", {"keys": '[{"code":4,"shift":true},{"code":42,"shift":false}]'})
            send.assert_awaited_once_with(worker.rsd, [(4, True), (42, False)])
            worker.start_mirror.reset_mock()
            for invalid in ['[{"code":4,"shift":false},{"code":224,"shift":false}]', '[]', '{}', 'bad']:
                with self.assertRaises(RpcError):
                    await worker.ui_command("keyboardInput", {"keys": invalid})
            worker.start_mirror.assert_not_awaited()
            audit.assert_not_called()
            self.assertEqual(send.await_count, 1)

    async def test_supervisor_routes_only_ios_and_preserves_selector(self):
        supervisor = Supervisor.__new__(Supervisor)
        worker = MagicMock()
        worker.call = AsyncMock(return_value={})
        supervisor._ios_record = MagicMock()
        supervisor._worker = AsyncMock(return_value=worker)
        for method in WORKER_UI_METHODS:
            await supervisor.dispatch(method, {"udid": "U", "selector": '{"id":"save"}'}, MagicMock())
            supervisor._ios_record.assert_called_with("U")
            worker.call.assert_awaited_with(method, {"selector": '{"id":"save"}'}, timeout=40)


class KeyboardTests(unittest.IsolatedAsyncioTestCase):
    async def test_failed_keyboard_report_releases_and_closes_without_replaying(self):
        keyboard = MagicMock()
        keyboard.connect = AsyncMock()
        keyboard.create_keyboard_service = AsyncMock(return_value=123)
        keyboard.send_keyboard = AsyncMock(side_effect=[ConnectionError("dropped"), None])
        keyboard.close = AsyncMock()
        with patch("devicehubd.ios_keyboard.UniversalHIDServiceService", return_value=keyboard):
            with self.assertRaisesRegex(RpcError, "partial"):
                await type_keys(object(), text_keys("Ab"))
        self.assertEqual(keyboard.send_keyboard.await_count, 2)
        self.assertEqual(keyboard.send_keyboard.await_args_list[0].args, (123, [225, 4]))
        self.assertEqual(keyboard.send_keyboard.await_args_list[1].args, (123, []))
        keyboard.close.assert_awaited_once()

class LivePhysicalUITests(unittest.IsolatedAsyncioTestCase):
    async def test_live_physical_hierarchy(self):
        import io
        import os
        udid = os.environ.get("PHONEUSE_PHYSICAL_UDID")
        if not udid:
            self.skipTest("Set PHONEUSE_PHYSICAL_UDID with an unlocked development-signed foreground app")
        worker = Worker(udid, os.environ.get("PHONEUSE_PHYSICAL_CONNECTION", "network"), io.BytesIO())
        try:
            await asyncio.wait_for(worker.start(), 45)
            tree = await worker.ui_command("describeUI", {})
            self.assertGreater(len(tree["elements"]), 0)
            self.assertEqual(tree["coordinateSpace"], "unavailable")
            self.assertFalse(any("frame" in row for row in tree["elements"]))
            # Do not write private screen labels or values to test logs.
            print(f"Physical hierarchy read: {len(tree['elements'])} elements, truncated={tree['truncated']}")
        finally:
            await worker.close()
