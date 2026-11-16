import PhoneUseKit
import SwiftUI

struct WirelessPairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: DeviceListModel
    @State private var status: WirelessPairingStatus?
    @State private var errorMessage: String?
    @State private var retryGeneration = 0
    @State private var choosingDevice = false
    @State private var client: DaemonClient?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("配对附近设备", systemImage: "wifi")
                .font(.title2.weight(.semibold))
            Text("将 iPhone / iPad 与这台 Mac 连接到同一 Wi-Fi。首次无线配对需要 iOS / iPadOS 27 或更新版本。")
                .font(.callout).foregroundStyle(.secondary)

            if status?.state == .paired {
                Label("已配对 \(status?.deviceName ?? "设备")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("设备已加入列表，可以选择设备进行连接。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                instructions
                if let pin = status?.pin {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("在设备上输入此验证码")
                        Text(pin)
                            .font(.system(size: 36, weight: .semibold, design: .monospaced))
                            .tracking(8)
                            .textSelection(.enabled)
                            .privacySensitive()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                nearbyDevices
            }

            if let message = errorMessage ?? status?.error ?? status?.discoveryError {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if status?.isActive == true {
                    ProgressView().controlSize(.small)
                    Text(status?.state == .pairing ? "正在配对，请在设备上完成确认…" : "正在发现附近设备…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if errorMessage != nil || status?.state == .failed {
                    Button("重试") { retryGeneration += 1 }
                }
                Button(status?.state == .paired ? "完成" : "取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .task(id: retryGeneration) { await run() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. 在设备的「设置 › 隐私与安全性」中开启「开发者模式」，按提示重启并确认。")
            Text("2. 打开「设置 › 开发者 › 已配对的 Mac」，选择下方这台电脑。")
            if let name = status?.hostName {
                Text(name).font(.callout.weight(.semibold)).textSelection(.enabled)
            }
            Text("3. 在设备上输入此窗口显示的验证码。若设备出现在下方列表，也可以直接点击「配对」。")
            Text("旧版系统或找不到开发者模式时，可先用 USB 连接、信任并完成设置，再通过 Wi-Fi 重连。")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var nearbyDevices: some View {
        if let status, !status.devices.isEmpty {
            Text("附近的可配对设备").font(.headline)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(status.devices) { device in
                        HStack {
                            Label(device.name, systemImage: "iphone")
                                .lineLimit(1)
                            Spacer()
                            Button("配对") { pair(device) }
                                .disabled(status.state != .waiting || choosingDevice)
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    @MainActor
    private func run() async {
        status = nil
        errorMessage = nil
        var sessionID: String?
        var daemon: DaemonClient?
        do {
            let connected = try await DeviceHub.shared.daemon()
            daemon = connected
            client = connected
            let initial = try await connected.startWirelessPairing()
            sessionID = initial.sessionID
            status = initial
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                let update = try await connected.wirelessPairingStatus(initial.sessionID)
                status = update
                if update.state == .paired {
                    // Refresh before selecting: the subscription notification may still be queued.
                    await model.selectPairedDevice(update.pairedUDID)
                }
                if !update.isActive { break }
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { errorMessage = "\(error)" }
        }
        // Uses the same connection and session ID, so dismissal or a retry can
        // never cancel another client's newer pairing window.
        if let daemon, let sessionID { try? await daemon.stopWirelessPairing(sessionID) }
        client = nil
    }

    private func pair(_ device: NearbyDevice) {
        guard let client, let status, !choosingDevice else { return }
        choosingDevice = true
        Task { @MainActor in
            defer { choosingDevice = false }
            do {
                try await client.pairNearbyDevice(device.id, sessionID: status.sessionID)
                errorMessage = nil
            } catch {
                errorMessage = "\(error)"
            }
        }
    }
}
