import CoreFoundation
import Foundation
import PhoneUseKit

enum MCPSettingsGroup: String, CaseIterable { case appearance, voiceOver = "voice_over", audio, locations }

enum MCPSettingsCommand {
    case read(MCPSettingsGroup), appearance(DeviceSettings.AppearanceChange), voiceOver(Bool)
    case audio(Int?, DeviceSettings.AudioRoute?, DeviceSettings.AudioRoute?)
    case preset(String), location(DeviceSettings.Location?)

    init(_ name: String, _ args: [String: Any]) throws {
        let keys = Set(args.keys).subtracting(["device"])
        func string(_ key: String) throws -> String { try MCPCommand.string(args, key)! }
        func boolean(_ key: String) throws -> Bool {
            guard let value = args[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw ToolFailure(message: "\(key) must be a boolean.")
            }
            return value.boolValue
        }
        func number(_ key: String, _ range: ClosedRange<Double>) throws -> Double {
            let value = try MCPCommand.number(args, key)
            guard range.contains(value) else { throw ToolFailure(message: "\(key) must be within \(range).") }
            return value
        }
        func option<T: RawRepresentable>(_ key: String, _: T.Type) throws -> T where T.RawValue == String {
            guard let result = T(rawValue: try string(key)) else { throw ToolFailure(message: "Unsupported \(key). See tools/list.") }
            return result
        }
        func route(_ key: String) throws -> DeviceSettings.AudioRoute? {
            guard keys.contains(key) else { return nil }
            let uid = try string(key)
            return uid == "systemDefault" ? .systemDefault : .device(uid)
        }
        switch name {
        case "get_device_settings": self = .read(try option("group", MCPSettingsGroup.self))
        case "set_appearance":
            guard keys.count == 1, let key = keys.first else { throw ToolFailure(message: "Supply exactly one appearance or accessibility setting.") }
            switch key {
            case "style": self = .appearance(.style(try option(key, DeviceSettings.InterfaceStyle.self)))
            case "tinted_glass": self = .appearance(.tintedLiquidGlass(try boolean(key)))
            case "glass_opacity": self = .appearance(.liquidGlassOpacity(try number(key, 0...1)))
            case "text_size": self = .appearance(.textSize(try option(key, DeviceSettings.TextSize.self)))
            case "color_filter": self = .appearance(.colorFilter(try string(key) == "off" ? nil : option(key, DeviceSettings.ColorFilter.self)))
            case "reduce_motion": self = .appearance(.reduceMotion(try boolean(key)))
            case "increase_contrast": self = .appearance(.increaseContrast(try boolean(key)))
            case "reduce_transparency": self = .appearance(.reduceTransparency(try boolean(key)))
            case "show_borders": self = .appearance(.showBorders(try boolean(key)))
            case "voice_over": self = .voiceOver(try boolean(key))
            default: throw ToolFailure(message: "Unknown appearance setting.")
            }
        case "set_audio":
            guard !keys.isEmpty else { throw ToolFailure(message: "Supply volume, input or output.") }
            let volume = keys.contains("volume") ? try number("volume", 0...100) : nil
            guard volume?.rounded() == volume else { throw ToolFailure(message: "volume must be an integer.") }
            self = .audio(volume.map(Int.init), try route("output"), try route("input"))
        case "set_location":
            if keys == ["clear"], try boolean("clear") { self = .location(nil) }
            else if keys == ["preset"] { self = .preset(try string("preset")) }
            else if keys == ["latitude", "longitude"] {
                self = .location(.init(name: "Coordinate", kind: .coordinate(latitude: try number("latitude", -90...90),
                                                                            longitude: try number("longitude", -180...180))))
            } else { throw ToolFailure(message: "Supply preset, a coordinate pair, or clear=true.") }
        default: throw ToolFailure(message: "Unknown settings tool.")
        }
    }

    func execute(_ device: DeviceSummary) async throws -> [String: Any] {
        guard let settings = await DeviceSettings.resolve(for: device) else {
            throw DeviceHubError.capabilityUnavailable("Apple device settings")
        }
        var result: [String: Any] = ["device": device.udid, "source": settings.source.rawValue]
        switch self {
        case .read(.appearance):
            let a = try await settings.appearance()
            result["style"] = a.style?.rawValue
            result["supported_looks"] = a.supportedLooksAndFeels
            result["look"] = a.lookAndFeel
            result["glass_opacity"] = a.liquidGlassOpacity
            result["supported_color_filters"] = a.supportedColorFilters.map(\.rawValue)
            if !a.supportedColorFilters.isEmpty { result["color_filter"] = a.colorFilter?.rawValue ?? "off" }
            result["text_size"] = a.textSize?.rawValue
            result["reduce_motion"] = a.reduceMotion
            result["increase_contrast"] = a.increaseContrast
            result["reduce_transparency"] = a.reduceTransparency
            result["show_borders"] = a.showBorders
        case .read(.voiceOver): result["voice_over"] = try await settings.voiceOver()
        case .read(.audio):
            let audio = try await settings.audio()
            func uid(_ route: DeviceSettings.AudioRoute) -> String {
                switch route { case .device(let id): id; case .systemDefault: "systemDefault" }
            }
            let host = HostAudioDevices()
            result["volume"] = audio.volume
            result["input"] = uid(audio.input)
            result["output"] = uid(audio.output)
            result["inputs"] = host.inputs.map { ["id": $0.id, "name": $0.name] }
            result["outputs"] = host.outputs.map { ["id": $0.id, "name": $0.name] }
        case .read(.locations): result["presets"] = try await settings.locations().map(\.name)
        case .appearance(let change): try await settings.apply(change)
        case .voiceOver(let enabled): try await settings.setVoiceOver(enabled)
        case .audio(let volume, let output, let input): try await settings.setAudio(volume: volume, output: output, input: input)
        case .location(let location): try await settings.simulate(location)
        case .preset(let name):
            guard let location = try await settings.locations().first(where: { $0.name == name }) else {
                throw ToolFailure(message: "Unknown preset. Query get_device_settings with group=locations for names.")
            }
            try await settings.simulate(location)
        }
        switch self {
        case .read: break
        default: result["applied"] = true
        }
        return try mcpObject(result)
    }
}
