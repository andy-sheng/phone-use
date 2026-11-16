import AppKit
import SwiftUI

/// Geometry of the compact window, which shows only the device frame and its controls.
enum CompactLayout {
    /// Space around the device frame.
    static let screenInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    /// The device controls below the frame.
    static let controlsHeight: CGFloat = 60
    static let minimumSize = CGSize(width: 300, height: 420)
    /// The longest side of the device frame, so a large display does not get a giant phone.
    static let maximumFrameLength: CGFloat = 760
    /// Fraction of the visible screen the compact window may use.
    static let screenFraction: CGFloat = 0.9

    /// The content size below the toolbar that fits the device frame snugly on a screen
    /// with `available` visible points, where `chromeHeight` is the title bar and toolbar.
    static func stageSize(screenAspectRatio: CGFloat, available: CGSize, chromeHeight: CGFloat) -> CGSize {
        let outer = DeviceFrame<EmptyView>.outerAspectRatio(screenAspectRatio: screenAspectRatio)
        let insetWidth = screenInsets.leading + screenInsets.trailing
        let insetHeight = screenInsets.top + screenInsets.bottom + controlsHeight
        let maxFrameWidth = min(maximumFrameLength, available.width * screenFraction - insetWidth)
        let maxFrameHeight = min(maximumFrameLength, available.height * screenFraction - chromeHeight - insetHeight)
        var frameHeight = max(maxFrameHeight, 1)
        var frameWidth = frameHeight * outer
        if frameWidth > maxFrameWidth {
            frameWidth = max(maxFrameWidth, 1)
            frameHeight = frameWidth / outer
        }
        return CGSize(width: max(minimumSize.width, (frameWidth + insetWidth).rounded(.up)),
                      height: max(minimumSize.height - chromeHeight, (frameHeight + insetHeight).rounded(.up)))
    }
}

/// Switches one window between the full workspace frame and a frame fitted to the device.
@MainActor
final class CompactWindowController {
    weak var window: NSWindow?
    private var expandedFrame: NSRect?

    var isCompact: Bool { expandedFrame != nil }

    func enter(screenAspectRatio: CGFloat) {
        guard let window, expandedFrame == nil else { return }
        expandedFrame = window.frame
        fit(screenAspectRatio: screenAspectRatio)
    }

    /// Resizes the compact window to the device, keeping its top-left corner where it was.
    func fit(screenAspectRatio: CGFloat) {
        guard let window, expandedFrame != nil, !window.styleMask.contains(.fullScreen) else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let chrome = max(window.frame.height - window.contentLayoutRect.height, 0)
        let stage = CompactLayout.stageSize(screenAspectRatio: screenAspectRatio,
                                            available: visible.size, chromeHeight: chrome)
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - stage.height - chrome,
                           width: stage.width, height: stage.height + chrome)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    func exit() {
        guard let frame = expandedFrame else { return }
        expandedFrame = nil
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.setFrame(frame, display: true, animate: true)
    }
}

/// Reports the window hosting a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onWindow: onWindow)
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
