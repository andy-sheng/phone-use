import XCTest
@testable import PhoneUseKit

final class UIAutomationTests: XCTestCase {
    private func element(_ type: String = "Button", id: String? = nil, label: String? = nil, enabled: Bool = true) -> UIElement {
        UIElement(type: type, id: id, label: label, value: nil, enabled: enabled,
                  frame: .init(x: 0, y: 0, width: 100, height: 30), depth: 0)
    }

    func testSelectorsRejectMissingAmbiguousAndDisabledTargets() throws {
        let rows = [element(id: "save", label: "Save"), element("TextField", id: "name", label: "Save")]
        XCTAssertEqual(try UISelector(id: "save").index(in: rows), 0)
        XCTAssertEqual(try UISelector(label: "Save", elementType: "TextField").index(in: rows), 1)
        XCTAssertThrowsError(try UISelector(label: "Save").index(in: rows))
        XCTAssertThrowsError(try UISelector(id: "missing").index(in: rows))
        XCTAssertThrowsError(try UISelector(id: "save").index(in: [element(id: "save", enabled: false)]))
        XCTAssertThrowsError(try UISelector(id: "save", label: "Save"))
        XCTAssertThrowsError(try UISelector(elementType: "Button"))
    }

    func testKeyboardMapsUSCharactersAndRejectsTheWholeUnsupportedString() throws {
        let text = "aA1!zZ0)[]{}\\|;'\":`~,<.>/? =+-_\n\t"
        let keys = try SimulatorKeyboard.keys(for: text)
        XCTAssertEqual(keys.count, text.count)
        XCTAssertEqual(keys[0], .init(code: 4, shift: false))
        XCTAssertEqual(keys[1], .init(code: 4, shift: true))
        XCTAssertEqual(keys[3], .init(code: 30, shift: true))
        XCTAssertEqual(keys.suffix(2).map(\.code), [40, 43])
        XCTAssertThrowsError(try SimulatorKeyboard.keys(for: "valid prefix 中文"))
        XCTAssertThrowsError(try SimulatorKeyboard.keys(for: "emoji 🎾"))
        XCTAssertThrowsError(try SimulatorKeyboard.keys(for: String(repeating: "a", count: 10001)))
    }

    func testModernHIDSelectionUsesLoadedCoreSimulatorVersion() {
        XCTAssertFalse(SimulatorInput.requiresModernHID(version: nil))
        XCTAssertFalse(SimulatorInput.requiresModernHID(version: "1155.3"))
        XCTAssertTrue(SimulatorInput.requiresModernHID(version: "1155.4"))
        XCTAssertTrue(SimulatorInput.requiresModernHID(version: "1155.10"))
        XCTAssertTrue(SimulatorInput.requiresModernHID(version: "1160.1"))
    }

    /// Opt-in read against an already-open simulator. Ordinary swift test is device-independent.
    func testLiveSimulatorAccessibility() async throws {
        guard let udid = ProcessInfo.processInfo.environment["DEVICEHUB_SIMULATOR_UDID"] else {
            throw XCTSkip("Set DEVICEHUB_SIMULATOR_UDID for the live accessibility check")
        }
        let tree = try await CoreSimulatorBridge.shared().accessibility(udid)
        XCTAssertGreaterThan(tree.elements.count, 1, "The foreground app should expose controls, not just an empty shell")
        XCTAssertFalse(tree.truncated)
        XCTAssertTrue(tree.elements.contains { $0.type == "Button" || $0.type == "TextField" })
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/simulator-ui-outline.txt")
        try tree.outline.write(to: output, atomically: true, encoding: .utf8)
    }

    /// Explicitly opt in to input; never runs during the ordinary regression suite.
    func testLiveSimulatorInteractions() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PHONEUSE_LIVE_UI_ACTIONS"] == "1", let udid = environment["DEVICEHUB_SIMULATOR_UDID"] else {
            throw XCTSkip("Opt in with PHONEUSE_LIVE_UI_ACTIONS=1 on a Settings test simulator")
        }
        let device = try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: [
            "udid": "simulator:\(udid)", "platform": "ios", "connection": "simulator",
            "name": "Automation test", "state": "ready", "session": "closed",
        ]))
        let (connection, display) = try await SimulatorDeviceConnection.open(device)
        let before = try await connection.uiTree()
        let general = try XCTUnwrap(before.elements.first { $0.id == "com.apple.settings.general" }, "Open Settings at its root before this opt-in test")
        let search = try XCTUnwrap(before.elements.first { $0.type == "TextField" && $0.label != nil })
        try await connection.activate(UISelector(id: general.id))
        try await Task.sleep(for: .milliseconds(500))
        let detail = try await connection.uiTree()
        XCTAssertTrue(detail.elements.contains { $0.type == "Heading" && $0.label == general.label })
        let backLabel = try XCTUnwrap(before.elements.first?.label)
        try await connection.activate(UISelector(label: backLabel, elementType: "Button"))
        try await Task.sleep(for: .milliseconds(500))
        // Also exercise the HID coordinate channel, independently of AX activation.
        let returned = try await connection.uiTree()
        let freshGeneral = try XCTUnwrap(returned.elements.first { $0.id == general.id })
        try await connection.tap(x: (freshGeneral.frame.x + freshGeneral.frame.width / 2) / display.pointWidth,
                                 y: (freshGeneral.frame.y + freshGeneral.frame.height / 2) / display.pointHeight)
        try await Task.sleep(for: .milliseconds(500))
        let tapped = try await connection.uiTree()
        guard tapped.elements.contains(where: { $0.type == "Heading" && $0.label == general.label }) else {
            XCTFail("Coordinate input did not navigate: \(tapped.outline)")
            return
        }
        try await connection.activate(UISelector(label: backLabel, elementType: "Button"))
        try await Task.sleep(for: .milliseconds(500))
        // Digits avoid locale/IME composition differences in this device-independent assertion.
        try await connection.typeText("424242", target: UISelector(label: search.label, elementType: "TextField"))
        try await Task.sleep(for: .milliseconds(500))
        let typed = try await connection.uiTree()
        XCTAssertTrue(typed.elements.contains { $0.type == "TextField" && $0.value == "424242" }, "HID delivery must be verified in the resulting field value")
        await connection.close()
    }
}
