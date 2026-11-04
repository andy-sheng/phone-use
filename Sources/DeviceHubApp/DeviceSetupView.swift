import DeviceHubKit
import SwiftUI

/// Walks the user through what a device needs before it can be mirrored and controlled.
struct DeviceSetupView: View {
    @EnvironmentObject private var model: AppModel
    let device: DeviceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: device.isPad ? "ipad" : "iphone")
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
        switch device.state {
        case .disconnected: "Not connected"
        case .probing: "Checking…"
        case .untrusted: "Trust this Mac"
        case .developerModeOff: "Turn on Developer Mode"
        case .developerImageMissing: "Preparing developer services"
        case .ready: "Ready"
        }
    }

    @ViewBuilder
    private var steps: some View {
        switch device.state {
        case .disconnected:
            Text("Connect \(device.name) to this Mac with a USB cable.")
        case .probing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading device information…")
            }
        case .untrusted:
            Step(number: 1, text: "Unlock the iPhone.")
            Step(number: 2, text: "Tap Trust when it asks whether to trust this computer, then enter the passcode.")
            actionButton("Ask to Trust This Mac", progress: "Waiting for the iPhone to trust this Mac…") {
                try await DeviceHub.shared.pair($0)
            }
        case .developerModeOff:
            Step(number: 1, text: "Make the Developer Mode switch appear on the iPhone.")
            actionButton("Show Developer Mode Setting", progress: "Revealing Developer Mode…") {
                try await DeviceHub.shared.revealDeveloperMode($0)
            }
            Step(number: 2, text: "On the iPhone, open Settings › Privacy & Security › Developer Mode and turn it on.")
            Step(number: 3, text: "Restart when asked. After the restart, unlock the iPhone and confirm Turn On.")
        case .developerImageMissing:
            Text("Installing developer services on the iPhone. The first time needs an internet connection.")
            actionButton("Retry", progress: "Installing developer services…") {
                try await DeviceHub.shared.mountDeveloperImage($0)
            }
        case .ready:
            EmptyView()
        }
    }

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
