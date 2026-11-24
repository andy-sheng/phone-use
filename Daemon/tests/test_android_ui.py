import unittest

from devicehubd.android_ui import ui_tree
from devicehubd.protocol import RpcError


class AndroidUITests(unittest.TestCase):
    def test_outline_order_labels_and_display_pixels(self):
        tree = ui_tree('''<?xml version="1.0"?><hierarchy rotation="1">
            <node class="Layout" bounds="[0,0][800,400]">
              <node class="Button" resource-id="app:id/save" content-desc="保存" text="Save &amp; close"
                    bounds="[10,20][110,60]" enabled="false"/>
              <node class="TextView" text="Hello" bounds="bad"/>
            </node></hierarchy>UI hierarchy dumped to: /dev/tty''')
        self.assertEqual(tree["coordinateSpace"], "display-pixels")
        self.assertFalse(tree["truncated"])
        layout, button, text = tree["elements"]
        self.assertEqual(layout["depth"], 0)
        self.assertEqual(button, {"type": "Button", "id": "app:id/save", "depth": 1, "label": "保存",
                                  "value": "Save & close", "enabled": False,
                                  "frame": {"x": 10, "y": 20, "width": 100, "height": 40}})
        self.assertEqual(text, {"type": "TextView", "depth": 1, "label": "Hello"})

    def test_password_text_and_description_are_omitted_including_descendants(self):
        tree = ui_tree('<hierarchy><node password="true" class="EditText" text="secret" content-desc="secret">'
                       '<node text="secret"/></node><node text="Visible"/></hierarchy>')
        self.assertNotIn("secret", str(tree))
        self.assertEqual(tree["elements"][-1]["label"], "Visible")

    def test_invalid_or_empty_dumps_are_errors(self):
        for output in ("ERROR: could not get idle state", "<hierarchy/>", "<hierarchy><node></hierarchy>"):
            with self.subTest(output=output), self.assertRaises(RpcError):
                ui_tree(output)

    def test_only_omitted_nodes_mark_the_tree_truncated(self):
        for count in (500, 501):
            tree = ui_tree("<hierarchy>" + "<node/>" * count + "</hierarchy>")
            self.assertEqual(len(tree["elements"]), 500)
            self.assertEqual(tree["truncated"], count > 500)
        tree = ui_tree("<hierarchy>" + "<node>" * 33 + "</node>" * 33 + "<node text='last'/></hierarchy>")
        self.assertTrue(tree["truncated"])
        self.assertEqual(max(row["depth"] for row in tree["elements"]), 31)
        self.assertEqual(tree["elements"][-1]["label"], "last")
