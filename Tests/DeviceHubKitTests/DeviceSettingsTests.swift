import Foundation
import XCTest
@testable import DeviceHubKit

final class DeviceSettingsTests: XCTestCase {
    // MARK: devicectl

    /// `devicectl device info appearance` for an iPhone Duo simulator with a color filter on.
    private let simulatorAppearance: [String: Any] = [
        "colorFilter": ["enabled": true, "filterType": ["name": "Deuteranopia"], "intensity": 0.7],
        "increaseContrast": false,
        "largerAccessibilitySizesEnabled": false,
        "liquidGlassOpacity": 0.5,
        "lookAndFeel": "Liquid Glass",
        "reduceMotion": ["enabled": true],
        "reduceTransparency": ["enabled": false],
        "showBorders": ["enabled": false],
        "supportedLooksAndFeels": ["Liquid Glass"],
        "textSize": "Extra Extra Extra Large",
        "userInterfaceStyle": "dark",
    ]

    func testDeviceCtlAppearanceReadsEverySetting() throws {
        let appearance = try DeviceCtlSettings.appearance(from: simulatorAppearance)
        XCTAssertEqual(appearance.style, .dark)
        XCTAssertEqual(appearance.liquidGlassOpacity, 0.5)
        XCTAssertEqual(appearance.supportedLooksAndFeels, ["Liquid Glass"])
        XCTAssertEqual(appearance.colorFilter, .deuteranopia)
        XCTAssertEqual(appearance.supportedColorFilters, DeviceSettings.ColorFilter.allCases)
        XCTAssertEqual(appearance.textSize, .extraExtraExtraLarge)
        XCTAssertEqual(appearance.reduceMotion, true)
        XCTAssertEqual(appearance.increaseContrast, false)
        XCTAssertEqual(appearance.showBorders, false)
    }

    func testDeviceCtlColorFilterOffReadsAsNone() throws {
        var result = simulatorAppearance
        result["colorFilter"] = ["enabled": false]
        XCTAssertNil(try DeviceCtlSettings.appearance(from: result).colorFilter)
    }

    func testDeviceCtlArguments() {
        XCTAssertEqual(DeviceCtlSettings.arguments(for: .style(.dark)), ["--mode", "dark"])
        XCTAssertEqual(DeviceCtlSettings.arguments(for: .colorFilter(nil)), ["--color-filter", "off"])
        XCTAssertEqual(DeviceCtlSettings.arguments(for: .colorFilter(.tritanopia)),
                       ["--color-filter", "on", "--color-filter-type", "tritanopia"])
        XCTAssertEqual(DeviceCtlSettings.arguments(for: .textSize(.small)), ["--text-size", "small"])
        XCTAssertEqual(DeviceCtlSettings.arguments(for: .textSize(.accessibilityLarge)),
                       ["--larger-accessibility-sizes", "on", "--text-size", "accessibility-large"])
        XCTAssertEqual(DeviceCtlSettings.arguments(for: .liquidGlassOpacity(1.4)), ["--liquid-glass-opacity", "1.00"])
        XCTAssertEqual(DeviceCtlSettings.arguments(for: .tintedLiquidGlass(true)), ["--look-and-feel", "tinted"])
    }

    func testDeviceCtlAudioRoutes() {
        XCTAssertEqual(DeviceCtlSettings.route(["systemDefault": [String: Any]()]), .systemDefault)
        XCTAssertEqual(DeviceCtlSettings.route(["device": ["_0": "BuiltInSpeakerDevice"]]), .device("BuiltInSpeakerDevice"))
    }

    func testDeviceCtlErrorDescription() {
        let document: [String: Any] = ["error": ["userInfo": ["NSLocalizedDescription": [
            "string": "The capability “Audio Output Device Selection” is not supported by this device.",
        ]]]]
        XCTAssertEqual(DeviceCtl.failure(in: document),
                       "The capability “Audio Output Device Selection” is not supported by this device.")
    }

    // MARK: Accessibility audit

    /// The audit service's settings as read from an iPhone with text size Small.
    private let auditSettings: [String: Any] = [
        "INVERT_COLORS": false, "INCREASE_CONTRAST": false, "REDUCE_TRANSPARENCY": true,
        "REDUCE_MOTION": false, "ON_OFF_LABELS": false, "BUTTON_SHAPES": true,
        "GRAYSCALE": false, "DIFFERENTIATE_WITHOUT_COLOR": false, "DYNAMIC_TYPE": 1.0 / 11.0,
    ]

    func testAuditAppearanceOffersOnlyWhatTheServiceHas() {
        let appearance = AccessibilityAuditSettings.appearance(from: auditSettings)
        XCTAssertNil(appearance.style)
        XCTAssertNil(appearance.liquidGlassOpacity)
        XCTAssertEqual(appearance.supportedColorFilters, [.grayscale])
        XCTAssertNil(appearance.colorFilter)
        XCTAssertEqual(appearance.textSize, .small)
        XCTAssertEqual(appearance.reduceTransparency, true)
        XCTAssertEqual(appearance.showBorders, true)
        XCTAssertEqual(appearance.reduceMotion, false)
    }

    func testAuditTextSizeSliderCoversEverySize() {
        for size in DeviceSettings.TextSize.allCases {
            XCTAssertEqual(AccessibilityAuditSettings.textSize(slider: AccessibilityAuditSettings.slider(for: size)), size)
        }
        XCTAssertEqual(AccessibilityAuditSettings.textSize(slider: 0), .extraSmall)
        XCTAssertEqual(AccessibilityAuditSettings.textSize(slider: 1), .accessibilityExtraExtraExtraLarge)
    }

    func testAuditSettingNames() {
        XCTAssertEqual(AccessibilityAuditSettings.setting(for: .reduceMotion(true))?.name, "REDUCE_MOTION")
        XCTAssertEqual(AccessibilityAuditSettings.setting(for: .showBorders(true))?.name, "BUTTON_SHAPES")
        XCTAssertEqual(AccessibilityAuditSettings.setting(for: .colorFilter(.grayscale))?.value as? Bool, true)
        XCTAssertEqual(AccessibilityAuditSettings.setting(for: .colorFilter(nil))?.value as? Bool, false)
        XCTAssertEqual(AccessibilityAuditSettings.setting(for: .textSize(.small))?.value as? Double, 1.0 / 11.0)
        XCTAssertNil(AccessibilityAuditSettings.setting(for: .style(.dark)))
        XCTAssertNil(AccessibilityAuditSettings.setting(for: .colorFilter(.protanopia)))
    }
}
