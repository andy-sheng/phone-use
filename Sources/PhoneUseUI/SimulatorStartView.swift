import PhoneUseKit
import SwiftUI

/// A powered-off simulator uses the same central Start interaction as Xcode's DeviceHub.
struct SimulatorStartView: View {
    let device: DeviceSummary
    let isStarting: Bool
    let status: String?
    let error: String?
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            deviceArtwork
                .padding(.bottom, 18)
            Text(device.name)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text([device.osDescription, "Simulator"].compactMap { $0 }.joined(separator: " "))
                .font(.callout)
                .foregroundStyle(.secondary)
            if isStarting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status ?? "Starting…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 12)
                Button("Cancel", action: cancel)
                    .glassButton()
                    .accessibilityIdentifier("simulator.start.cancel")
            } else {
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 360)
                }
                Button(error == nil ? "Start" : "Retry", action: start)
                    .glassButton()
                    .controlSize(.large)
                    .padding(.top, 12)
                    .accessibilityIdentifier("simulator.start")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceArtwork: some View {
        RoundedRectangle(cornerRadius: device.isPad ? 14 : 19, style: .continuous)
            .fill(.black)
            .overlay {
                RoundedRectangle(cornerRadius: device.isPad ? 11 : 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.55, blue: 0.80),
                                                  Color(red: 0.32, green: 0.69, blue: 0.94)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(3)
            }
            .overlay(alignment: .top) {
                if !device.isPad {
                    Capsule().fill(.black).frame(width: 22, height: 7).padding(.top, 8)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: device.isPad ? 14 : 19, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .frame(width: device.isPad ? 144 : 90, height: 192)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 4)
            .accessibilityHidden(true)
    }
}
