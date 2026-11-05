import DeviceHubKit
import SwiftUI

/// Walks the user through what a device needs before it can be mirrored and controlled.
struct DeviceSetupView: View {
    @EnvironmentObject private var model: AppModel
    let device: DeviceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: device.deviceIcon)
                    .font(.system(size: 26, weight: .light))
                    .frame(width: 48, height: 48)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.title3.weight(.semibold))
                    Text(headline).font(.callout).foregroundStyle(.secondary)
                }
            }
            steps
            if let progress = model.actionInProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.secondary)
                }
            }
            if let error = model.actionError ?? device.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(28)
        .glassCard(cornerRadius: 26)
    }

    private var headline: String {
        if device.isAndroid {
            return switch device.state {
            case .disconnected: "Not connected"
            case .probing: "Checking…"
            case .unauthorized, .untrusted: "Allow USB debugging"
            case .offline: "Device is offline"
            case .ready: "Ready"
            default: "Enable USB debugging"
            }
        }
        return switch device.state {
        case .disconnected: "Not connected"
        case .probing: "Checking…"
        case .untrusted: "Trust this Mac"
        case .unauthorized: "Authorize this computer"
        case .offline: "Device is offline"
        case .developerModeOff: "Turn on Developer Mode"
        case .developerImageMissing: "Preparing developer services"
        case .ready: "Ready"
        }
    }

    @ViewBuilder
    private var steps: some View {
        if device.isAndroid {
            androidSteps
        } else {
            appleSteps
        }
    }

    @ViewBuilder
    private var androidSteps: some View {
        switch device.state {
        case .probing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading device information…")
            }
        case .unauthorized, .untrusted:
            Step(number: 1, text: "Unlock the Android device and keep it connected with a USB cable.")
            Step(number: 2, text: "Accept the Allow USB debugging prompt on the device. You can select Always allow from this computer.")
            Step(number: 3, text: "If the prompt does not appear, reconnect the USB cable and check that USB debugging is enabled in Developer options.")
        case .offline:
            Step(number: 1, text: "Unlock the Android device and reconnect the USB cable.")
            Step(number: 2, text: "If it remains offline, turn USB debugging off and on in Developer options, then accept the authorization prompt.")
            Text("The device list updates automatically when the connection is ready.")
                .foregroundStyle(.secondary)
        case .ready:
            EmptyView()
        default:
            Step(number: 1, text: "Connect the Android device to this Mac with a USB data cable and unlock it.")
            Step(number: 2, text: "In Settings, enable Developer options and turn on USB debugging. On most devices, tap Build number seven times to enable Developer options.")
            Step(number: 3, text: "Accept the Allow USB debugging prompt on the device.")
        }
    }

    @ViewBuilder
    private var appleSteps: some View {
        switch device.state {
        case .disconnected:
            if device.wireless == true {
                Text("Connect \(device.name) to this Mac with a USB cable, or unlock it on the same Wi-Fi network as this Mac.")
            } else {
                Text("Connect \(device.name) to this Mac with a USB cable.")
            }
        case .probing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading device information…")
            }
        case .untrusted, .unauthorized:
            Step(number: 1, text: "Unlock the \(appleDeviceName).")
            Step(number: 2, text: "Tap Trust when it asks whether to trust this computer, then enter the passcode.")
            actionButton("Ask to Trust This Mac", progress: "Waiting for the \(appleDeviceName) to trust this Mac…") {
                try await DeviceHub.shared.pair($0)
            }
        case .offline:
            Text("Unlock \(device.name) and reconnect it to this Mac with a USB cable.")
        case .developerModeOff:
            Step(number: 1, text: "Make the Developer Mode switch appear on the \(appleDeviceName).")
            actionButton("Show Developer Mode Setting", progress: "Revealing Developer Mode…") {
                try await DeviceHub.shared.revealDeveloperMode($0)
            }
            Step(number: 2, text: "On the \(appleDeviceName), open Settings › Privacy & Security › Developer Mode and turn it on.")
            Step(number: 3, text: "Restart when asked. After the restart, unlock the \(appleDeviceName) and confirm Turn On.")
        case .developerImageMissing:
            Text("Installing developer services on the \(appleDeviceName). The first time needs an internet connection.")
            actionButton("Retry", progress: "Installing developer services…") {
                try await DeviceHub.shared.mountDeveloperImage($0)
            }
        case .ready:
            EmptyView()
        }
    }

    private var appleDeviceName: String { device.isPad ? "iPad" : "iPhone" }

    private func actionButton(_ title: String, progress: String,
                              _ action: @escaping (String) async throws -> Void) -> some View {
        Button(title) { model.perform(progress, action) }
            .glassButton(prominent: true)
            .controlSize(.large)
            .disabled(model.actionInProgress != nil)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 24, height: 24)
                .glassSurface(in: Circle(), tint: .accentColor.opacity(0.35))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
