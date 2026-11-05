import DeviceHubKit
import SwiftUI

/// Details about the selected device, shown in the trailing inspector.
struct DeviceInspector: View {
    let device: DeviceSummary
    @ObservedObject var screen: ScreenModel

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Name", value: device.name)
                LabeledContent("Platform", value: device.platformName)
                LabeledContent("Model", value: device.modelName ?? "–")
                LabeledContent("System", value: device.osDescription ?? "–")
                LabeledContent("Build", value: device.buildVersion ?? "–")
                LabeledContent("Connection", value: device.connectionDescription)
                LabeledContent(device.isAndroid ? "Serial" : "UDID") {
                    Text(device.deviceIdentifier)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section("Readiness") {
                if device.isAndroid {
                    Check("USB debugging authorized", device.paired)
                } else {
                    Check("Trusted", device.paired)
                    Check("Developer Mode", device.developerMode)
                    Check("Developer services", device.developerImage ?? (device.isReady ? true : nil))
                    Check("Wi-Fi", device.wireless)
                }
                LabeledContent("Session", value: device.session.capitalized)
            }
            if let display = screen.display {
                Section("Screen") {
                    LabeledContent("Resolution", value: "\(Int(display.pixelWidth)) × \(Int(display.pixelHeight)) px")
                    LabeledContent("Points", value: "\(Int(display.pointWidth)) × \(Int(display.pointHeight)) @\(Int(display.pointScale))x")
                    LabeledContent("Source", value: screen.stream?.kind.rawValue ?? "–")
                    LabeledContent("Frame rate", value: screen.framesPerSecond.map { String(format: "%.0f fps", $0) } ?? "–")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct Check: View {
    let title: String
    let value: Bool?

    init(_ title: String, _ value: Bool?) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title) {
            switch value {
            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
            case nil: Text("–").foregroundStyle(.secondary)
            }
        }
    }
}
