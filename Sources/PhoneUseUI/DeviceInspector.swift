import PhoneUseKit
import SwiftUI

/// Details about the selected device, shown in the trailing inspector.
public struct DeviceInspector: View {
    let device: DeviceSummary
    @ObservedObject var screen: ScreenModel

    public init(device: DeviceSummary, screen: ScreenModel) {
        self.device = device
        self.screen = screen
    }

    public var body: some View {
        Form {
            Section("Device") {
                Row("Name", "tag", device.name)
                Row("Platform", device.deviceIcon, device.platformName)
                Row("Model", "cpu", device.modelName ?? "–")
                Row("System", "gearshape", device.osDescription ?? "–")
                Row("Build", "hammer", device.buildVersion ?? "–")
                Row("Connection", device.isSimulator ? "macbook" : device.isWired ? "cable.connector" : "wifi",
                    device.connectionDescription)
                LabeledContent {
                    Text(device.deviceIdentifier)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label(device.isAndroid ? "Serial" : "UDID", systemImage: "number")
                }
            }
            Section("Readiness") {
                if device.isAndroid {
                    Check("USB debugging authorized", "hand.raised", device.paired)
                } else if device.isSimulator {
                    Check("Booted", "power", device.isAttached)
                } else {
                    Check("Trusted", "checkmark.shield", device.paired)
                    Check("Developer Mode", "hammer", device.developerMode)
                    Check("Developer services", "wrench.and.screwdriver", device.developerImage ?? (device.isReady ? true : nil))
                    Check("Wi-Fi", "wifi", device.wireless)
                    if device.isWired, let systemWifi = device.systemWifi {
                        SystemWifiToggle(udid: device.udid, enabled: systemWifi)
                    }
                }
                Row("Session", "link", device.session.capitalized)
            }
            if let display = screen.display {
                Section("Screen") {
                    Row("Resolution", "rectangle.dashed", "\(Int(display.pixelWidth)) × \(Int(display.pixelHeight)) px")
                    Row("Points", "square.resize", "\(Int(display.pointWidth)) × \(Int(display.pointHeight)) @\(Int(display.pointScale))x")
                    Row("Source", "video", screen.stream?.kind.rawValue ?? "–")
                    Row("Frame rate", "speedometer", screen.framesPerSecond.map { String(format: "%.0f fps", $0) } ?? "–")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Finder's "Show this iPhone when on Wi-Fi": a second way over Wi-Fi that does not depend on this
/// app's own Wi-Fi pairing. It can only be changed while the device is on USB.
private struct SystemWifiToggle: View {
    let udid: String
    let enabled: Bool
    @State private var pending: Bool?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { pending ?? enabled }, set: { change(to: $0) })) {
                Label("Wi-Fi through macOS", systemImage: "wifi.router")
            }
            .disabled(pending != nil)
            .help("Lets macOS reach this device over Wi-Fi as Finder and Xcode do, as a fallback when this app's own Wi-Fi pairing stops working.")
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .onChange(of: enabled) { _, _ in pending = nil }
    }

    private func change(to value: Bool) {
        pending = value
        error = nil
        Task {
            do {
                try await DeviceHub.shared.setSystemWifi(udid, enabled: value)
            } catch {
                self.error = String(describing: error)
                pending = nil
            }
        }
    }
}

/// A labelled value with a leading symbol, in the style of a settings row.
private struct Row: View {
    let title: String
    let systemImage: String
    let value: String

    init(_ title: String, _ systemImage: String, _ value: String) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value).textSelection(.enabled)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct Check: View {
    let title: String
    let systemImage: String
    let value: Bool?

    init(_ title: String, _ systemImage: String, _ value: Bool?) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
    }

    var body: some View {
        LabeledContent {
            switch value {
            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
            case nil: Text("–").foregroundStyle(.secondary)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
