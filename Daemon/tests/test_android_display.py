import subprocess
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from devicehubd.android_display import DisplayGeometry, parse_display_geometry, read_display_geometry
from devicehubd.protocol import RpcError


class DisplayGeometryTests(unittest.TestCase):
    def test_uses_default_viewport_instead_of_virtual_or_inactive_displays(self):
        output = """
  Viewport VIRTUAL: displayId=10, orientation=0, logicalFrame=[0, 0, 640, 480], isActive=[1]
  Viewport INTERNAL: displayId=0, orientation=0, logicalFrame=[0, 0, 480, 640], isActive=[0]
  Viewport INTERNAL: displayId=0, uniqueId=local:123, orientation=1, logicalFrame=[0, 0, 2400, 1080], physicalFrame=[0, 0, 2400, 1080], deviceSize=[1080, 2400], isActive=[1]
"""
        self.assertEqual(parse_display_geometry(output), DisplayGeometry(2400, 1080, 1))

    def test_older_viewport_format_and_nonzero_frame_origin(self):
        self.assertEqual(parse_display_geometry("Viewport: displayId=0, orientation=2, logicalFrame=[10, 20, 1090, 2420]"),
                         DisplayGeometry(1080, 2400, 2))

    def test_missing_or_invalid_default_display_fails_without_guessing(self):
        for output in ("", "Viewport: displayId=1, orientation=0, logicalFrame=[0, 0, 1080, 2400]",
                       "Viewport: displayId=0, orientation=9, logicalFrame=[0, 0, 1080, 2400]",
                       "Viewport: displayId=0, orientation=0, logicalFrame=[0, 0, 0, 2400]"):
            with self.subTest(output=output), self.assertRaises(RpcError) as caught:
                parse_display_geometry(output)
            self.assertEqual(caught.exception.code, "displayCheckFailed")

    def test_probe_reads_metadata_with_bounded_timeout_and_no_shell_interpolation(self):
        output = "Viewport: displayId=0, orientation=0, logicalFrame=[0, 0, 1080, 2400]"
        with patch("devicehubd.android_display.subprocess.run", return_value=SimpleNamespace(returncode=0, stdout=output)) as run:
            self.assertEqual(read_display_geometry("/a path/adb", "serial:5555"), DisplayGeometry(1080, 2400, 0))
        self.assertEqual(run.call_args.args[0], ["/a path/adb", "-s", "serial:5555", "shell", "dumpsys", "input"])
        self.assertEqual(run.call_args.kwargs["timeout"], 2)
        self.assertNotIn("shell", run.call_args.kwargs)

    def test_probe_errors_are_not_replaced_with_cached_geometry(self):
        for error in (OSError("offline"), subprocess.TimeoutExpired("adb", 2)):
            with self.subTest(error=error), patch("devicehubd.android_display.subprocess.run", side_effect=error), self.assertRaises(RpcError):
                read_display_geometry("/adb", "serial")
        with patch("devicehubd.android_display.subprocess.run", return_value=SimpleNamespace(returncode=1, stdout="", stderr="device offline")), self.assertRaisesRegex(RpcError, "device offline"):
            read_display_geometry("/adb", "serial")
