import PhoneUseKit
import SwiftUI

/// The device stage before starting a simulator or opening a screen preview.
struct DeviceStandbyView: View {
    let device: DeviceSummary
    let isConnecting: Bool
    let status: String?
    let error: String?
    let connect: () -> Void
    let cancel: () -> Void

    private var isStarting: Bool { device.canStartSimulator }

    var body: some View {
        VStack(spacing: 16) {
            deviceArtwork
                .padding(.bottom, 6)
            VStack(spacing: 4) {
                Text(device.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text([device.osDescription ?? device.platformName,
                      device.isSimulator || device.connection == "emulator" ? device.connectionDescription : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if isConnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status ?? (isStarting ? "Starting…" : "Connecting…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", action: cancel)
                    .glassButton()
                    .accessibilityIdentifier(isStarting ? "simulator.start.cancel" : "device.connection.cancel")
            } else {
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 360)
                }
                Button(action: connect) {
                    if isStarting {
                        Text(error == nil ? "Start" : "Retry")
                    } else {
                        Label(error == nil ? "View Screen" : "Retry", systemImage: "rectangle.inset.filled")
                    }
                }
                .glassButton(prominent: !isStarting)
                .controlSize(.large)
                .accessibilityIdentifier(isStarting ? "simulator.start" : "device.connect")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceArtwork: some View {
        let frame = DeviceFrameStyle(device)
        let ratio: CGFloat = device.isPad ? 3.0 / 4.0 : 393.0 / 852.0
        let size = DeviceFrame<EmptyView>.outerSize(screenWidth: 170 * ratio, screenAspectRatio: ratio)
        return DeviceFrame(screenAspectRatio: ratio, style: frame) {
            LinearGradient(colors: [Color(red: 0.13, green: 0.34, blue: 0.60),
                                    Color(red: 0.25, green: 0.65, blue: 0.77)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.65))
                    .frame(width: size.width * 0.32, height: 2)
                    .padding(.bottom, 6)
            }
            .overlay(alignment: .top) {
                if frame == .iPhone {
                    Capsule().fill(.black.opacity(0.85)).frame(width: 20, height: 5).padding(.top, 6)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}
