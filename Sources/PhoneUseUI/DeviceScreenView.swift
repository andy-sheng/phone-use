import PhoneUseKit
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
        VStack(spacing: 14) {
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                Text(status ?? "正在连接…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("取消", action: cancel)
                    .glassButton()
                    .accessibilityIdentifier("device.connection.cancel")
            } else {
                Image(systemName: device.deviceIcon)
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
                Text(device.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(error ?? "连接后即可查看并操作设备屏幕")
                    .font(.callout)
                    .foregroundStyle(error == nil ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .frame(maxWidth: 360)
                Button(error == nil ? "连接" : "重试", action: connect)
                    .glassButton(prominent: true)
                    .controlSize(.large)
                    .padding(.top, 4)
                    .accessibilityIdentifier("device.connect")
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(minWidth: 260)
        .glassCard(cornerRadius: 28)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The live device screen in a device frame. Device controls live in the window toolbar.
struct DeviceScreenView: View {
    @ObservedObject var screen: ScreenModel
    let stream: any ScreenStream
    var allowsInput = true
    var frameStyle = DeviceFrameStyle.iPhone
    /// Screen points per view point, or nil to fit the window.
    var zoom: CGFloat?
    /// Reports the scale that fits the current window, so zooming can start from it.
    var onFitScale: (CGFloat) -> Void = { _ in }

    /// Space kept around the device frame. The control bar below the stage adds its own spacing.
    var insets = EdgeInsets(top: 32, leading: 32, bottom: 12, trailing: 32)

    var body: some View {
        GeometryReader { area in
            let fitScale = fittedScale(in: area.size)
            let size = frameSize(in: area.size, fitScale: fitScale)
            // One scroll view for both fitting and zooming, so changing the zoom animates the
            // frame's size instead of swapping views. Like the window's toolbar, it runs under
            // the title bar and the floating controls.
            ScrollView([.horizontal, .vertical]) {
                frame
                    .frame(width: size.width, height: size.height)
                    .padding(insets)
                    .frame(minWidth: area.size.width, minHeight: area.size.height)
            }
            .scrollIndicators(.never)
            .scrollDisabled(zoom == nil)
            .defaultScrollAnchor(.center, for: .initialOffset)
            .defaultScrollAnchor(.center, for: .sizeChanges)
            .defaultScrollAnchor(.center, for: .alignment)
            .hiddenScrollEdgeEffect()
            .animation(.smooth(duration: 0.35), value: zoom)
            .onChange(of: fitScale, initial: true) { _, scale in onFitScale(scale) }
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
            }
            .padding(.bottom, 20)
            .animation(.smooth, value: screen.notice)
        }
    }

    private var frame: some View {
        DeviceFrame(screenAspectRatio: screen.aspectRatio, style: frameStyle) {
            ScreenSurface(
                screenLayer: stream.layer,
                acceptsInput: allowsInput && screen.streamError == nil && !screen.isReconnecting && !screen.isChangingGeometry,
                onTouch: { phase, point in screen.touch(phase, at: point) }
            )
        }
    }

    /// The device frame's size: the zoomed screen width, or the largest frame that fits.
    private func frameSize(in area: CGSize, fitScale: CGFloat) -> CGSize {
        let ratio = screen.aspectRatio
        if let zoom, let points = screen.display?.pointWidth, points > 0 {
            return DeviceFrame<EmptyView>.outerSize(screenWidth: points * zoom, screenAspectRatio: ratio)
        }
        let outer = DeviceFrame<EmptyView>.outerAspectRatio(screenAspectRatio: ratio)
        let width = max(min(area.width - insets.leading - insets.trailing,
                            (area.height - insets.top - insets.bottom) * outer), 1)
        return CGSize(width: width, height: width / outer)
    }

    private func fittedScale(in size: CGSize) -> CGFloat {
        guard let points = screen.display?.pointWidth, points > 0 else { return 1 }
        let outer = DeviceFrame<EmptyView>.outerAspectRatio(screenAspectRatio: screen.aspectRatio)
        let width = max(min(size.width - insets.leading - insets.trailing,
                            (size.height - insets.top - insets.bottom) * outer), 1)
        return width * (1 - 2 * DeviceFrame<EmptyView>.bezelFraction) / points
    }
}

/// Which hardware buttons a device frame shows along its edges.
enum DeviceFrameStyle {
    case iPhone, iPad, android

    init(_ device: DeviceSummary?) {
        if device?.isAndroid == true {
            self = .android
        } else if device?.isPad == true {
            self = .iPad
        } else {
            self = .iPhone
        }
    }

    /// A button on one edge of the upright device, placed by fractions of that edge's length.
    struct SideButton {
        enum Edge { case leading, trailing, top }
        let edge: Edge
        let start: CGFloat
        let length: CGFloat
    }

    var sideButtons: [SideButton] {
        switch self {
        case .iPhone:
            [.init(edge: .leading, start: 0.17, length: 0.045),
             .init(edge: .leading, start: 0.25, length: 0.08),
             .init(edge: .leading, start: 0.35, length: 0.08),
             .init(edge: .trailing, start: 0.28, length: 0.12)]
        case .iPad:
            [.init(edge: .top, start: 0.78, length: 0.08),
             .init(edge: .trailing, start: 0.07, length: 0.05),
             .init(edge: .trailing, start: 0.13, length: 0.05)]
        case .android:
            [.init(edge: .trailing, start: 0.2, length: 0.1),
             .init(edge: .trailing, start: 0.34, length: 0.065)]
        }
    }
}

/// A device-like bezel. The inner screen keeps the device's exact aspect ratio, so normalized
/// touch coordinates over it map one-to-one to the framebuffer.
struct DeviceFrame<Content: View>: View {
    let screenAspectRatio: CGFloat
    var style = DeviceFrameStyle.iPhone
    @ViewBuilder var content: Content

    static var bezelFraction: CGFloat { 0.035 }
    private let bezelFraction = DeviceFrame<EmptyView>.bezelFraction
    private let screenCornerFraction: CGFloat = 0.13
    /// The metal band around the black bezel, as a fraction of the short side.
    private let bandFraction: CGFloat = 0.009
    /// How far side buttons stand out from the band, as a fraction of the short side.
    private let buttonFraction: CGFloat = 0.011

    static func outerAspectRatio(screenAspectRatio: CGFloat) -> CGFloat {
        1 / ((1 - 2 * bezelFraction) / screenAspectRatio + 2 * bezelFraction)
    }

    /// The bezel's size around a screen of the given width.
    static func outerSize(screenWidth: CGFloat, screenAspectRatio: CGFloat) -> CGSize {
        let width = screenWidth / (1 - 2 * bezelFraction)
        return CGSize(width: width, height: width / outerAspectRatio(screenAspectRatio: screenAspectRatio))
    }

    private var outerAspectRatio: CGFloat {
        Self.outerAspectRatio(screenAspectRatio: screenAspectRatio)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let shortSide = min(size.width, size.height)
            let bezel = size.width * bezelFraction
            let band = max(shortSide * bandFraction, 1.5)
            let screenRadius = shortSide * screenCornerFraction
            let outer = RoundedRectangle(cornerRadius: screenRadius + bezel, style: .continuous)
            let inner = RoundedRectangle(cornerRadius: screenRadius + bezel - band, style: .continuous)
            ZStack {
                // Drawn first, so only the part standing out of the band shows.
                ForEach(Array(style.sideButtons.enumerated()), id: \.offset) { _, button in
                    let rect = buttonRect(button, in: size, thickness: max(shortSide * buttonFraction, 2))
                    RoundedRectangle(cornerRadius: min(rect.width, rect.height) / 2)
                        .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.2)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                outer
                    .fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.2), Color(white: 0.3)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
                inner
                    .fill(Color(white: 0.04))
                    .padding(band)
                outer
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
                content
                    .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
                    .padding(bezel)
            }
        }
        .aspectRatio(outerAspectRatio, contentMode: .fit)
    }

    /// The button's rectangle in frame coordinates. Positions are given for the upright device
    /// and turn with it when the screen is landscape.
    private func buttonRect(_ button: DeviceFrameStyle.SideButton, in size: CGSize, thickness: CGFloat) -> CGRect {
        let width = min(size.width, size.height)
        let height = max(size.width, size.height)
        // Reaches under the band, so the button meets the frame without a gap.
        let depth = thickness * 2
        let upright: CGRect = switch button.edge {
        case .leading: CGRect(x: -thickness, y: button.start * height, width: depth, height: button.length * height)
        case .trailing: CGRect(x: width - thickness, y: button.start * height, width: depth, height: button.length * height)
        case .top: CGRect(x: button.start * width, y: -thickness, width: button.length * width, height: depth)
        }
        guard size.width > size.height else { return upright }
        // Turned a quarter clockwise: the upright leading edge becomes the top.
        return CGRect(x: height - upright.maxY, y: upright.minX, width: upright.height, height: upright.width)
    }
}
