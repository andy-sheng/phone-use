import CoreGraphics
import Foundation
import ImageIO

/// Device service names and message shapes, as served by the Developer Disk Image daemons.
enum DeviceService {
    static let universalHID = "com.apple.coredevice.hid.universalhidservice"
    static let indigoHID = "com.apple.coredevice.hid.indigo"
    static let screenCapture = "com.apple.coredevice.screencaptureservice"
    static let deviceInfo = "com.apple.coredevice.deviceinfo"
    static let appService = "com.apple.coredevice.appservice"
}

/// The request envelope CoreDevice services (`screencaptureservice`, `deviceinfo`, `appservice`) expect.
enum CoreDeviceInvocation {
    static func request(feature: String, input: XPCValue, action: String? = nil) -> XPCDictionary {
        var request: XPCDictionary = [
            "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(2),
            "CoreDevice.coreDeviceVersion": [
                "components": [.uint64(629), .uint64(3)],
                "originalComponentsCount": .int64(2),
                "stringValue": "629.3",
            ],
            "CoreDevice.deviceIdentifier": .string(UUID().uuidString),
            "CoreDevice.input": input,
            "CoreDevice.invocationIdentifier": .string(UUID().uuidString),
            "CoreDevice.featureIdentifier": .string(feature),
            "CoreDevice.action": [:],
        ]
        if let action {
            request["CoreDevice.actionIdentifier"] = .string(action)
        }
        return request
    }

    static func output(of reply: XPCDictionary, feature: String) throws -> XPCValue {
        if let output = reply["CoreDevice.output"] { return output }
        let detail = reply["CoreDevice.error"]?["userInfo"]?["NSLocalizedDescription"]?.stringValue
        throw DeviceHubError.serviceFailed("\(feature) failed: \(detail ?? "\(reply)")")
    }
}

enum HIDReports {
    /// `_ServiceID` of the device's built-in touchscreen surface.
    static let mainTouchscreen: UInt64 = 257
    static let contact: UInt8 = 0xC2
    static let release: UInt8 = 0x02

    /// A 58-byte touchscreen report carrying one contact: `[0x09][count][max=5][5-byte slots]…[0x02 0 0 0][timestamp]`.
    static func touchscreen(state: UInt8, x: Double, y: Double) -> Data {
        var report = [UInt8](repeating: 0, count: 58)
        report[0] = 0x09
        report[1] = 1
        report[2] = 5
        let hidX = UInt16((min(max(x, 0), 1) * 65535).rounded())
        let hidY = UInt16((min(max(y, 0), 1) * 65535).rounded())
        report[3] = state
        report[4] = UInt8(hidX & 0xFF)
        report[5] = UInt8(hidX >> 8)
        report[6] = UInt8(hidY & 0xFF)
        report[7] = UInt8(hidY >> 8)
        report[40] = 0x02
        let timestamp = mach_absolute_time() & 0xFFFF_FFFF_FFFF
        for index in 0..<6 {
            report[44 + index] = UInt8((timestamp >> (8 * UInt64(index))) & 0xFF)
        }
        return Data(report)
    }

    static func touchMessage(_ report: Data, service: UInt64 = mainTouchscreen) -> XPCDictionary {
        [
            "featureIdentifier": "com.apple.coredevice.feature.remote.universalhidservice",
            "messageType": "Request",
            "payload": ["send": ["_0": .data(report), "_1": .uint64(service)]],
        ]
    }

    static func buttonMessage(page: UInt64, code: UInt64, down: Bool) -> XPCDictionary {
        [
            "messageType": "IndigoButtonEvent",
            "payload": [
                "state": .uint64(down ? 1 : 2),
                "usagePage": .uint64(page),
                "usageCode": .uint64(code),
            ],
            "featureIdentifier": "com.apple.coredevice.feature.remote.hid.button",
        ]
    }
}

enum ScreenCapture {
    static let feature = "com.apple.coredevice.feature.capturescreenshot"

    static func request() -> XPCDictionary {
        CoreDeviceInvocation.request(
            feature: feature,
            input: ["displayUniqueID": .null, "requestedFormat": "png"],
            action: "com.apple.coredevice.action.capturescreenshot")
    }

    static func image(from reply: XPCDictionary) throws -> CGImage {
        let output = try CoreDeviceInvocation.output(of: reply, feature: feature)
        guard let data = output["image"]?.dataValue,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DeviceHubError.serviceFailed("The screenshot could not be decoded")
        }
        return image
    }
}

enum DisplayQuery {
    static let feature = "com.apple.coredevice.feature.getdisplayinfo"

    static func request() -> XPCDictionary {
        CoreDeviceInvocation.request(feature: feature, input: [:])
    }

    static func primaryDisplay(from reply: XPCDictionary) throws -> DisplayInfo {
        let output = try CoreDeviceInvocation.output(of: reply, feature: feature)
        let displays = output["displays"]?.arrayValue ?? []
        guard let primary = displays.first(where: { $0["primary"]?.boolValue == true }) ?? displays.first,
              let size = primary["nativeSize"]?.arrayValue, size.count == 2,
              let width = size[0].doubleValue, let height = size[1].doubleValue, width > 0, height > 0 else {
            throw DeviceHubError.serviceFailed("The device reported no primary display")
        }
        return DisplayInfo(pixelWidth: width, pixelHeight: height, pointScale: primary["pointScale"]?.doubleValue ?? 3)
    }
}

enum AppLaunch {
    static let feature = "com.apple.coredevice.feature.launchapplication"

    static func request(bundleID: String) -> XPCDictionary {
        let options = (try? PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)) ?? Data()
        return CoreDeviceInvocation.request(feature: feature, input: [
            "applicationSpecifier": ["bundleIdentifier": ["_0": .string(bundleID)]],
            "options": [
                "arguments": [],
                "environmentVariables": [:],
                "standardIOUsesPseudoterminals": true,
                "startStopped": false,
                "terminateExisting": true,
                "user": ["shortName": "mobile"],
                "platformSpecificOptions": .data(options),
            ],
            "standardIOIdentifiers": [:],
        ])
    }
}
