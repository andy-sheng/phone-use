import PhoneUseKit
import PhoneUseUI
import SwiftUI

/// The selected device's appearance, accessibility, location and audio settings, read from the
/// device and applied as soon as a control changes.
@MainActor
final class DeviceSettingsModel: ObservableObject {
    typealias Settings = DeviceSettings

    @Published private(set) var appearance: Settings.Appearance?
    @Published private(set) var voiceOver: Bool?
    @Published private(set) var audio: Settings.Audio?
    @Published private(set) var locations: [Settings.Location] = []
    @Published private(set) var location: Settings.Location?
    @Published private(set) var source: Settings.Source?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    /// The last change the device rejected.
    @Published private(set) var error: String?

    private var settings: Settings?
    private var deviceID: String?

    func load(_ device: DeviceSummary) async {
        deviceID = device.id
        settings = nil
        source = nil
        appearance = nil
        voiceOver = nil
        audio = nil
        locations = []
        location = nil
        error = nil
        loadError = nil
        isLoading = true
        defer { if deviceID == device.id { isLoading = false } }
        guard let settings = await Settings.resolve(for: device),
              deviceID == device.id, !Task.isCancelled else { return }
        self.settings = settings
        source = settings.source
        // Each group is optional: a device lacking one capability still shows the others.
        async let appearance = attempt { try await settings.appearance() }
        async let voiceOver = attempt { try await settings.voiceOver() }
        async let audio = attempt { try await settings.audio() }
        async let locations = attempt { try await settings.locations() }
        let loaded = await (appearance, voiceOver, audio, locations)
        guard deviceID == device.id, !Task.isCancelled else { return }
        self.appearance = try? loaded.0.get()
        self.voiceOver = try? loaded.1.get()
        self.audio = try? loaded.2.get()
        self.locations = (try? loaded.3.get()) ?? []
        if case .failure(let failure) = loaded.0, self.voiceOver == nil, self.audio == nil {
            loadError = String(describing: failure)
        }
    }

    func apply(_ change: Settings.AppearanceChange, update: (inout Settings.Appearance) -> Void) {
        guard let settings, var current = appearance else { return }
        let previous = current
        update(&current)
        appearance = current
        perform({ try await settings.apply(change) }, revert: { [weak self] in self?.appearance = previous })
    }

    func setVoiceOver(_ enabled: Bool) {
        guard let settings else { return }
        let previous = voiceOver
        voiceOver = enabled
        perform({ try await settings.setVoiceOver(enabled) }, revert: { [weak self] in self?.voiceOver = previous })
    }

    func setAudio(volume: Int? = nil, output: Settings.AudioRoute? = nil, input: Settings.AudioRoute? = nil) {
        guard let settings, var current = audio else { return }
        let previous = current
        if let volume { current.volume = volume }
        if let output { current.output = output }
        if let input { current.input = input }
        audio = current
        perform({ try await settings.setAudio(volume: volume, output: output, input: input) },
                revert: { [weak self] in self?.audio = previous })
    }

    func simulate(_ location: Settings.Location?) {
        guard let settings else { return }
        let previous = self.location
        self.location = location
        perform({ try await settings.simulate(location) }, revert: { [weak self] in self?.location = previous })
    }

    private func perform(_ operation: @escaping @Sendable () async throws -> Void, revert: @escaping @MainActor () -> Void) {
        let deviceID = deviceID
        error = nil
        Task {
            do {
                try await operation()
            } catch {
                guard self.deviceID == deviceID else { return }
                revert()
                self.error = String(describing: error)
            }
        }
    }
}

private func attempt<Value: Sendable>(_ body: @Sendable () async throws -> Value) async -> Result<Value, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

/// Device settings in the style of Xcode's device window: grouped rows with a leading symbol.
struct DeviceSettingsPanel: View {
    let device: DeviceSummary?
    @StateObject private var model = DeviceSettingsModel()
    @State private var textSizeIndex: Double = 3
    @State private var glassOpacity: Double = 0.5
    @State private var volume: Double = 50
    @State private var hostAudio: HostAudioDevices?

    var body: some View {
        Group {
            if let device, device.isAndroid {
                ContentUnavailableView("暂不支持 Android", systemImage: "switch.2",
                                       description: Text("设备设置目前适用于 iPhone、iPad 和模拟器。"))
            } else if let device, !device.isReady {
                ContentUnavailableView("设备尚未就绪", systemImage: device.deviceIcon)
            } else if device == nil {
                ContentUnavailableView("未选择设备", systemImage: "iphone")
            } else if model.isLoading && model.appearance == nil {
                ProgressView().controlSize(.small)
            } else if let failure = model.loadError {
                ContentUnavailableView {
                    Label("无法读取设备设置", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("重试") { reload() }.glassButton()
                }
            } else {
                form
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: device.map { "\($0.id)|\($0.isReady)" }) {
            guard let device, device.isReady else { return }
            await model.load(device)
            syncSliders()
        }
    }

    private func reload() {
        guard let device else { return }
        Task {
            await model.load(device)
            syncSliders()
        }
    }

    private func syncSliders() {
        if model.audio != nil { hostAudio = HostAudioDevices() }
        if let size = model.appearance?.textSize {
            textSizeIndex = Double(DeviceSettings.TextSize.standard.firstIndex(of: size)
                                   ?? DeviceSettings.TextSize.standard.count - 1)
        }
        glassOpacity = model.appearance?.liquidGlassOpacity ?? 0.5
        volume = Double(model.audio?.volume ?? 50)
    }

    private var form: some View {
        Form {
            if let appearance = model.appearance {
                Section { appearanceRows(appearance) }
            } else if let voiceOver = model.voiceOver {
                Section { voiceOverRow(voiceOver) }
            }
            if !model.locations.isEmpty {
                Section {
                    SettingRow("Location", "location") {
                        Picker("Location", selection: Binding(get: { model.location }, set: { model.simulate($0) })) {
                            Text("None").tag(DeviceSettings.Location?.none)
                            Divider()
                            ForEach(model.locations) { Text($0.name).tag(Optional($0)) }
                        }
                    }
                }
            }
            if let audio = model.audio {
                Section { audioRows(audio) }
            }
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            if let source = model.source {
                Section {
                    Text(sourceDescription(source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func appearanceRows(_ appearance: DeviceSettings.Appearance) -> some View {
        if let style = appearance.style {
            SettingRow("Appearance", "circle.lefthalf.filled") {
                Picker("Appearance", selection: Binding(get: { style }, set: { style in
                    model.apply(.style(style)) { $0.style = style }
                })) {
                    Text("Light").tag(DeviceSettings.InterfaceStyle.light)
                    Text("Dark").tag(DeviceSettings.InterfaceStyle.dark)
                }
            }
        }
        if appearance.supportedLooksAndFeels.count > 1 {
            let tinted = appearance.lookAndFeel?.localizedCaseInsensitiveContains("tinted") == true
            SettingRow("Liquid Glass", "rectangle.on.rectangle") {
                Picker("Liquid Glass", selection: Binding(get: { tinted }, set: { tinted in
                    let name = appearance.supportedLooksAndFeels.first {
                        $0.localizedCaseInsensitiveContains(tinted ? "tinted" : "clear")
                    }
                    model.apply(.tintedLiquidGlass(tinted)) { $0.lookAndFeel = name }
                })) {
                    Text("Clear").tag(false)
                    Text("Tinted").tag(true)
                }
            }
        } else if appearance.liquidGlassOpacity != nil {
            SettingRow("Liquid Glass", "rectangle.on.rectangle") {
                Slider(value: $glassOpacity, in: 0...1) { editing in
                    guard !editing else { return }
                    let value = glassOpacity
                    model.apply(.liquidGlassOpacity(value)) { $0.liquidGlassOpacity = value }
                }
                .frame(width: 130)
            }
        }
        if appearance.supportedColorFilters == [.grayscale] {
            toggle("Grayscale", "camera.filters", appearance.colorFilter == .grayscale) { on in
                model.apply(.colorFilter(on ? .grayscale : nil)) { $0.colorFilter = on ? .grayscale : nil }
            }
        } else if !appearance.supportedColorFilters.isEmpty {
            SettingRow("Color Filter", "camera.filters") {
                Picker("Color Filter", selection: Binding(get: { appearance.colorFilter }, set: { filter in
                    model.apply(.colorFilter(filter)) { $0.colorFilter = filter }
                })) {
                    Text("None").tag(DeviceSettings.ColorFilter?.none)
                    Divider()
                    ForEach(appearance.supportedColorFilters, id: \.self) { filter in
                        Text(Self.title(of: filter)).tag(Optional(filter))
                    }
                }
            }
        }
        if appearance.textSize != nil {
            SettingRow("Text Size", "textformat.size") {
                Slider(value: $textSizeIndex, in: 0...Double(DeviceSettings.TextSize.standard.count - 1), step: 1) { editing in
                    guard !editing else { return }
                    let size = DeviceSettings.TextSize.standard[Int(textSizeIndex.rounded())]
                    model.apply(.textSize(size)) { $0.textSize = size }
                }
                .frame(width: 130)
            }
        }
        if let on = appearance.reduceMotion {
            toggle("Reduce Motion", "circle.dotted.circle", on) { on in
                model.apply(.reduceMotion(on)) { $0.reduceMotion = on }
            }
        }
        if let on = appearance.increaseContrast {
            toggle("Increase Contrast", "circle.righthalf.filled", on) { on in
                model.apply(.increaseContrast(on)) { $0.increaseContrast = on }
            }
        }
        if let on = appearance.showBorders {
            toggle("Show Borders", "square.dashed", on) { on in
                model.apply(.showBorders(on)) { $0.showBorders = on }
            }
        }
        if let on = appearance.reduceTransparency {
            toggle("Reduce Transparency", "square.on.square.intersection.dashed", on) { on in
                model.apply(.reduceTransparency(on)) { $0.reduceTransparency = on }
            }
        }
        if let voiceOver = model.voiceOver {
            voiceOverRow(voiceOver)
        }
    }

    private static func title(of filter: DeviceSettings.ColorFilter) -> String {
        switch filter {
        case .grayscale: "Grayscale"
        case .protanopia: "Red/Green"
        case .deuteranopia: "Green/Red"
        case .tritanopia: "Blue/Yellow"
        }
    }

    private func sourceDescription(_ source: DeviceSettings.Source) -> String {
        switch source {
        case .xcode: "通过 Xcode（devicectl）读写设置"
        case .deviceServices: "通过设备服务调整，仅在 PhoneUse 连接此设备期间生效，断开后恢复。安装 Xcode 27 或更高版本后会直接修改设备设置，并可调整外观、VoiceOver、声音和录屏。"
        case .simctl: "通过 simctl 读写设置。Xcode 27 或更高版本提供更多选项。"
        }
    }

    private func voiceOverRow(_ enabled: Bool) -> some View {
        toggle("VoiceOver", "person.wave.2", enabled) { model.setVoiceOver($0) }
    }

    @ViewBuilder
    private func audioRows(_ audio: DeviceSettings.Audio) -> some View {
        if audio.volume != nil {
            SettingRow("Sound", "speaker.wave.2") {
                Slider(value: $volume, in: 0...100) { editing in
                    guard !editing else { return }
                    model.setAudio(volume: Int(volume.rounded()))
                }
                .frame(width: 130)
            }
        }
        SettingRow("Output", "headphones") {
            routePicker("Output", selection: audio.output, devices: hostAudio?.outputs ?? []) { model.setAudio(output: $0) }
        }
        SettingRow("Input", "mic") {
            routePicker("Input", selection: audio.input, devices: hostAudio?.inputs ?? []) { model.setAudio(input: $0) }
        }
    }

    private func routePicker(_ title: String, selection: DeviceSettings.AudioRoute,
                             devices: [HostAudioDevices.Device],
                             set: @escaping (DeviceSettings.AudioRoute) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: set)) {
            Text("System").tag(DeviceSettings.AudioRoute.systemDefault)
            if !devices.isEmpty { Divider() }
            ForEach(devices) { Text($0.name).tag(DeviceSettings.AudioRoute.device($0.id)) }
            // Keeps a device that is no longer attached selectable as the current value.
            if case .device(let uid) = selection, !devices.contains(where: { $0.id == uid }) {
                Text(uid).tag(selection)
            }
        }
    }

    private func toggle(_ title: String, _ systemImage: String, _ value: Bool,
                        set: @escaping (Bool) -> Void) -> some View {
        SettingRow(title, systemImage) {
            Toggle(title, isOn: Binding(get: { value }, set: set))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A settings row: a symbol and title, with its control trailing.
private struct SettingRow<Control: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var control: Control

    init(_ title: String, _ systemImage: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control.labelsHidden()
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            }
        }
    }
}
