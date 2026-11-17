import Foundation

/// Public names follow sim-use's cross-platform verbs. Older PhoneUse names remain callable.
enum MCPToolCatalog {
    static let aliases = ["get_screen": "screenshot", "press_button": "button", "ui": "describe_ui", "snapshot_ui": "describe_ui"]
    static let buttonNames = ["home", "lock", "side-button", "siri", "volume-up", "volume-down", "back", "recents"]

    static let definitions: [[String: Any]] = {
        let device: [String: Any] = ["type": "string", "minLength": 1,
            "description": "Device name, UDID or identifier from list_devices. May be omitted only when one ready device is connected. Use an explicit identifier when several devices match."]
        let duration: [String: Any] = ["type": "number", "exclusiveMinimum": 0, "maximum": 10,
            "description": "Duration in seconds, greater than 0 and at most 10. Do not combine with legacy duration_ms."]
        let delay: [String: Any] = ["type": "number", "minimum": 0, "maximum": 10,
            "description": "Delay in seconds (0–10)."]
        let common: [String: Any] = ["device": device,
            "pre_delay": delay, "post_delay": delay,
            "return_screen": ["type": "boolean", "default": false,
                "description": "Capture a screenshot 0.6 seconds after the action and post_delay. A capture failure does not replay the action."]]
        let coordinate: [String: Any] = ["type": "number", "minimum": 0,
            "description": "Screenshot coordinate: iOS points, Android pixels; origin at top-left. iOS uses the native portrait framebuffer."]
        let observe = " Observe with screenshot before acting, then verify the resulting screen; input delivery alone does not confirm a UI change."
        let selectors: [String: Any] = [
            "id": ["type": "string", "minLength": 1, "description": "Exact accessibility identifier from describe_ui (iOS simulator only)."],
            "label": ["type": "string", "minLength": 1, "description": "Exact accessibility label (iOS simulator only)."],
            "label_contains": ["type": "string", "minLength": 1, "description": "Case-sensitive label substring (iOS simulator only)."],
            "element_type": ["type": "string", "minLength": 1, "description": "Optional accessibility role filter, such as Button or TextField. Requires a selector."],
        ]

        func tool(_ name: String, _ description: String, _ fields: [String: Any],
                  required: [String] = [], oneOf: [[String]] = [], action: Bool = true) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": fields,
                                        "required": required, "additionalProperties": false]
            if !oneOf.isEmpty { schema["oneOf"] = oneOf.map { ["required": $0] } }
            return ["name": name, "description": description,
             "inputSchema": schema,
             "annotations": ["readOnlyHint": !action, "destructiveHint": false,
                             "idempotentHint": !action, "openWorldHint": true]]
        }
        func fields(_ extra: [String: Any]) -> [String: Any] { common.merging(extra) { _, new in new } }

        return [
            tool("list_devices", "List attached iOS/Android devices and booted iOS simulators (connection: simulator). Only state: ready devices can be controlled. Multiple ready devices require an explicit device argument.", [:], action: false),
            tool("screenshot", "Capture a JPEG image and coordinate metadata. One image pixel corresponds to one input coordinate: iOS points or Android pixels. iOS uses native portrait coordinates, not orientation-calibrated UI coordinates.", ["device": device], action: false),
            tool("describe_ui", "Read the foreground app's accessibility tree (iOS simulators only). Prefer id, then label selectors from this result. Frames use accessibility UI points; use screenshot for native coordinate taps. Not all custom-rendered controls expose accessibility; use screenshot for visual checks. Run again after each action.",
                 ["device": device, "format": ["type": "string", "enum": ["outline", "json"], "default": "outline"]], action: false),
            tool("tap", "Tap x/y, OR activate exactly one id/label/label_contains selector (simulator only), optionally filtered by element_type. Selectors are resolved fresh and must match exactly one enabled element; no cached aliases. duration is supported for coordinate taps only (e.g. 0.05 seconds for a switch)." + observe,
                 fields(selectors.merging(["x": coordinate, "y": coordinate, "duration": duration]) { _, new in new }),
                 oneOf: [["x", "y"], ["id"], ["label"], ["label_contains"]]),
            tool("long_press", "Touch and hold a screen coordinate. duration is in seconds (default 0.8), following sim-use long-press." + observe,
                 fields(["x": coordinate, "y": coordinate, "duration": duration,
                         "duration_ms": ["type": "integer", "minimum": 1, "maximum": 10000,
                                         "description": "Legacy hold duration in milliseconds; use duration instead."]]), required: ["x", "y"]),
            tool("swipe", "Move one finger from start to end. Dragging up moves content up and reveals content below. duration is in seconds (default 0.3). Use gesture for common scrolling and edge gestures." + observe,
                 fields(["start_x": coordinate, "start_y": coordinate, "end_x": coordinate, "end_y": coordinate,
                         "duration": duration,
                         "from_x": coordinate, "from_y": coordinate, "to_x": coordinate, "to_y": coordinate,
                         "duration_ms": ["type": "integer", "minimum": 1, "maximum": 10000,
                                         "description": "Legacy milliseconds; do not combine with duration."]]),
                 oneOf: [["start_x", "start_y", "end_x", "end_y"], ["from_x", "from_y", "to_x", "to_y"]]),
            tool("gesture", "Perform a single-finger preset using the actual screen size. scroll-up moves content UP (page DOWN); other directions name finger movement. Edge gestures may open system UI depending on the OS. duration defaults to 0.5 seconds for scrolls, 0.3 for edges. iOS directions use native portrait coordinates." + observe,
                 fields(["preset": ["type": "string", "enum": MCPGesture.allCases.map(\.rawValue)],
                         "duration": duration]), required: ["preset"]),
            tool("button", "Press a hardware button. side-button maps to lock; recents is Android app switch. back/recents are Android-only and siri is iOS-only. Optional hold duration is in seconds." + observe,
                 fields(["button": ["type": "string", "enum": buttonNames], "duration": duration]), required: ["button"]),
            tool("launch_app", "Launch or relaunch an installed app using an iOS bundle identifier or Android package/activity name." + observe,
                 fields(["bundle_id": ["type": "string", "minLength": 1]]), required: ["bundle_id"]),
            tool("type_text", "Type into the focused field, optionally focusing exactly one id/label/label_contains selector first (iOS simulator only). Uses US keyboard HID like sim-use type: ASCII letters, digits, punctuation, space, newline and tab; Unicode text must use the on-screen input method. Input follows the active keyboard/IME, so inspect composition/candidates as well as the field. Inserts at the current caret/selection without clearing existing text. Unsupported text is rejected in full before focus or typing. Inspect the field after errors before retrying.",
                 fields(selectors.merging(["text": ["type": "string", "minLength": 1, "maxLength": 10000]]) { _, new in new }), required: ["text"]),
        ]
    }()

}
