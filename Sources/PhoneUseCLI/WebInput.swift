import Foundation
import PhoneUseKit

enum WebInputCommand: Equatable {
    case tap(Double, Double, aspect: Double)
    case longPress(Double, Double, milliseconds: Int, aspect: Double)
    case swipe(Double, Double, Double, Double, milliseconds: Int, aspect: Double)
    case press(HardwareButton)

    private struct Payload: Decodable {
        let action: String
        var x: Double?, y: Double?, toX: Double?, toY: Double?
        var duration: Int?, aspect: Double?, button: String?
    }

    static func decode(_ data: Data) throws -> WebInputCommand {
        let value = try JSONDecoder().decode(Payload.self, from: data)
        func coordinate(_ number: Double?) throws -> Double {
            guard let number, number.isFinite, (0...1).contains(number) else {
                throw DeviceHubError.serviceFailed("坐标必须在 0 到 1 之间")
            }
            return number
        }
        func aspect() throws -> Double {
            guard let ratio = value.aspect, ratio.isFinite, (0.1...10).contains(ratio) else {
                throw DeviceHubError.serviceFailed("缺少画面尺寸，请刷新网页")
            }
            return ratio
        }
        func duration() throws -> Int {
            guard let duration = value.duration, (50...2000).contains(duration) else {
                throw DeviceHubError.serviceFailed("手势时长必须在 50 到 2000 毫秒之间")
            }
            return duration
        }
        switch value.action {
        case "tap": return try .tap(coordinate(value.x), coordinate(value.y), aspect: aspect())
        case "longpress": return try .longPress(coordinate(value.x), coordinate(value.y), milliseconds: duration(), aspect: aspect())
        case "swipe": return try .swipe(coordinate(value.x), coordinate(value.y), coordinate(value.toX), coordinate(value.toY),
                                       milliseconds: duration(), aspect: aspect())
        case "press":
            guard let name = value.button, let button = HardwareButton(rawValue: name), button != .siri else {
                throw DeviceHubError.serviceFailed("不支持的按键")
            }
            return .press(button)
        default: throw DeviceHubError.serviceFailed("不支持的操作")
        }
    }

    func execute(on session: DeviceSession) async throws {
        func checkGeometry(_ aspect: Double) throws {
            let display = session.display
            let expected = display.pixelWidth / display.pixelHeight
            guard abs(aspect / expected - 1) < 0.03 else {
                throw DeviceHubError.serviceFailed("画面方向与输入坐标不一致，请恢复竖屏或重新连接设备")
            }
        }
        // Complete gestures are submitted on pointer release. Browser disconnects cannot leave
        // a finger held down; failed device operations get a best-effort final release as well.
        var release: (Double, Double)?
        do {
            switch self {
            case let .tap(x, y, aspect):
                try checkGeometry(aspect)
                release = (x, y)
                try await session.tap(x: x, y: y)
            case let .longPress(x, y, milliseconds, aspect):
                try checkGeometry(aspect)
                release = (x, y)
                try await session.longPress(x: x, y: y, duration: .milliseconds(milliseconds))
            case let .swipe(x, y, toX, toY, milliseconds, aspect):
                try checkGeometry(aspect)
                release = (toX, toY)
                try await session.swipe(fromX: x, fromY: y, toX: toX, toY: toY, duration: .milliseconds(milliseconds))
            case let .press(button):
                try await session.press(button)
            }
        } catch {
            if let (x, y) = release { try? await session.sendTouch(.ended, x: x, y: y) }
            throw error
        }
    }
}
