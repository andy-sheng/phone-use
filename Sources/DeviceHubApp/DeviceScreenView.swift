import DeviceHubKit
import SwiftUI

/// Selection shows an idle screen until the user explicitly opens its preview.
struct DeviceConnectionView: View {
    let device: DeviceSummary
    let isConnecting: Bool
    let status: String?
    let error: String?
    let connect: () -> Void
    let cancel: () -> Void

    var body: some View {
        DeviceFrame(screenAspectRatio: device.isPad ? 3.0 / 4.0 : 393.0 / 852.0) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                VStack(spacing: 16) {
                    Image(systemName: device.deviceIcon)
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(device.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    if isConnecting {
                        ProgressView().controlSize(.regular)
                        Text(status ?? "正在连接…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("取消", action: cancel)
                            .glassButton()
                            .accessibilityIdentifier("device.connection.cancel")
                    } else {
                        Button(error == nil ? "连接" : "重试", action: connect)
                            .glassButton(prominent: true)
                            .controlSize(.large)
                            .accessibilityIdentifier("device.connect")
                        Text(error ?? "点击连接，查看并操作设备屏幕")
                            .font(.caption)
                            .foregroundStyle(error == nil ? Color.secondary : Color.orange)
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 52)
        .padding(.bottom, 84)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The live device screen in a device frame, with floating glass controls.
struct DeviceScreenView: View {
    @ObservedObject var screen: ScreenModel
    let stream: any ScreenStream
    var allowsInput = true
    @State private var showingLaunch = false
    @State private var bundleID = ""

    var body: some View {
        DeviceFrame(screenAspectRatio: screen.aspectRatio) {
            ScreenSurface(
                screenLayer: stream.layer,
                acceptsInput: allowsInput && screen.streamError == nil && !screen.isReconnecting,
                onTouch: { phase, point in screen.touch(phase, at: point) },
                onFlick: { start, delta in screen.flick(from: start, by: delta) }
            )
        }
        .padding(.top, 52)
        .padding(.bottom, 84)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            StreamBadge(kind: stream.kind, framesPerSecond: screen.framesPerSecond)
                .padding(.top, 12)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if !allowsInput {
                    Label("自动化运行中，停止任务后可手动操作", systemImage: "lock")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassCapsule()
                }
                if let notice = screen.streamError ?? screen.notice ?? screen.fallbackMessage {
                    HStack(spacing: 10) {
                        Text(notice)
                            .font(.callout)
                            .lineLimit(3)
                        if screen.isAndroid && (screen.streamError != nil || screen.fallbackMessage != nil) {
                            Button("Reconnect") {
                                guard allowsInput else { return }
                                Task { await screen.reconnect() }
                            }
                            .glassButton()
                            .disabled(!allowsInput || screen.isReconnecting)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassCapsule()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                controls
            }
            .padding(.bottom, 20)
            .animation(.smooth, value: screen.notice)
        }
        .onChange(of: allowsInput) { _, enabled in
            if !enabled { showingLaunch = false }
        }
    }

    private var controls: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    if screen.isAndroid {
                        ControlButton("Back", systemImage: "chevron.backward") { screen.press(.back) }
                    }
                    ControlButton("Home", systemImage: "house") { screen.press(.home) }
                    if screen.isAndroid {
                        ControlButton("Recent Apps", systemImage: "square.on.square") { screen.press(.appSwitch) }
                    }
                    ControlButton("Lock", systemImage: "lock") { screen.press(.lock) }
                    ControlButton("Volume Down", systemImage: "speaker.wave.1") { screen.press(.volumeDown) }
                    ControlButton("Volume Up", systemImage: "speaker.wave.3") { screen.press(.volumeUp) }
                }
                .disabled(!allowsInput)
                .padding(4)
                .glassCapsule()
                HStack(spacing: 4) {
                    ControlButton("Save Screenshot", systemImage: "camera.viewfinder") { screen.saveScreenshot() }
                    ControlButton("Launch App", systemImage: "app.badge") { showingLaunch.toggle() }
                        .disabled(!allowsInput)
                        .popover(isPresented: $showingLaunch, arrowEdge: .top) { launchPopover }
                }
                .padding(4)
                .glassCapsule()
            }
        }
        .environment(\.controlSize, screen.isAndroid ? .small : .regular)
    }

    private var launchPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Launch App").font(.headline)
            TextField(screen.isAndroid ? "Package name, e.g. com.android.settings" : "Bundle identifier, e.g. com.apple.Preferences", text: $bundleID)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(launch)
            HStack {
                Spacer()
                Button("Launch", action: launch)
                    .glassButton(prominent: true)
                    .disabled(bundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func launch() {
        guard allowsInput else { return }
        screen.launchApp(bundleID: bundleID.trimmingCharacters(in: .whitespaces))
        showingLaunch = false
    }
}

private struct ControlButton: View {
    @Environment(\.controlSize) private var controlSize
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: controlSize == .small ? 30 : 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct StreamBadge: View {
    let kind: ScreenStreamKind
    let framesPerSecond: Double?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text(kind.rawValue)
            if let framesPerSecond {
                Text(String(format: "%.0f fps", framesPerSecond))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassCapsule()
    }
}

/// A device-like bezel. The inner screen keeps the device's exact aspect ratio, so normalized
/// touch coordinates over it map one-to-one to the framebuffer.
struct DeviceFrame<Content: View>: View {
    let screenAspectRatio: CGFloat
    @ViewBuilder var content: Content

    private let bezelFraction: CGFloat = 0.035
    private let screenCornerFraction: CGFloat = 0.13

    private var outerAspectRatio: CGFloat {
        1 / ((1 - 2 * bezelFraction) / screenAspectRatio + 2 * bezelFraction)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let bezel = width * bezelFraction
            let screenRadius = width * screenCornerFraction
            let outer = RoundedRectangle(cornerRadius: screenRadius + bezel, style: .continuous)
            ZStack {
                outer
                    .fill(Color(white: 0.05))
                    .overlay(
                        outer.strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06), .white.opacity(0.3)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
                content
                    .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
                    .padding(bezel)
            }
        }
        .aspectRatio(outerAspectRatio, contentMode: .fit)
    }
}
