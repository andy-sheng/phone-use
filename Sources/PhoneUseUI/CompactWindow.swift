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
final class CompactWindowController: ObservableObject {
    weak var stage: NSView?
    @Published private(set) var isCompact = false
    @Published private(set) var isResizing = false
    private var expandedFrame: NSRect?
    private struct TitlebarAppearance {
        let transparent: Bool
        let separator: NSTitlebarSeparatorStyle
        let background: NSColor
        let fullSizeContent: Bool
    }

    private var expandedTitlebar: TitlebarAppearance?
    private var revision = 0

    func setCompact(_ compact: Bool, screenAspectRatio: CGFloat, reduceMotion: Bool) {
        guard compact != isCompact, let stage, let window = stage.window else { return }
        let fullscreen = window.styleMask.contains(.fullScreen)
        if compact, expandedFrame == nil, !fullscreen { expandedFrame = window.frame }

        // Measure before the sidebar or inspector moves. The compact window closes around
        // the preview even when the user has dragged either divider away from its default.
        let centerX = window.convertToScreen(stage.convert(stage.bounds, to: nil)).midX
        let target = compact ? compactFrame(in: window, ratio: screenAspectRatio, centerX: centerX) : expandedFrame
        updateTitlebar(in: window, compact: compact)
        let resize = !fullscreen && target != nil
        isResizing = resize
        let duration = target.map { window.animationResizeTime($0) } ?? 0.25
        withAnimation(reduceMotion ? nil : .easeInOut(duration: duration)) {
            isCompact = compact
        }
        if resize, let target {
            resizeWindow(window, to: target, reduceMotion: reduceMotion)
        } else {
            revision += 1
            if !compact { expandedFrame = nil }
        }
    }

    private func updateTitlebar(in window: NSWindow, compact: Bool) {
        if compact {
            let fullSizeContent = window.styleMask.contains(.fullSizeContentView)
            expandedTitlebar = TitlebarAppearance(transparent: window.titlebarAppearsTransparent,
                                                  separator: window.titlebarSeparatorStyle,
                                                  background: window.backgroundColor, fullSizeContent: fullSizeContent)
            // Extend the stage beneath the native toolbar and match its backing during the resize.
            if !fullSizeContent { window.styleMask.insert(.fullSizeContentView) }
            window.backgroundColor = .underPageBackgroundColor
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        } else if let expandedTitlebar {
            if !expandedTitlebar.fullSizeContent { window.styleMask.remove(.fullSizeContentView) }
            window.backgroundColor = expandedTitlebar.background
            window.titlebarAppearsTransparent = expandedTitlebar.transparent
            window.titlebarSeparatorStyle = expandedTitlebar.separator
            self.expandedTitlebar = nil
        }
    }

    func fit(screenAspectRatio: CGFloat, reduceMotion: Bool) {
        guard isCompact, let window = stage?.window, !window.styleMask.contains(.fullScreen) else { return }
        let target = compactFrame(in: window, ratio: screenAspectRatio, centerX: window.frame.midX)
        resizeWindow(window, to: target, reduceMotion: reduceMotion)
    }

    private func compactFrame(in window: NSWindow, ratio: CGFloat, centerX: CGFloat) -> NSRect {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let chrome = max(window.frame.height - window.contentLayoutRect.height, 0)
        let stageSize = CompactLayout.stageSize(screenAspectRatio: ratio, available: visible.size, chromeHeight: chrome)
        let size = CGSize(width: stageSize.width, height: stageSize.height + chrome)
        return NSRect(x: min(max((centerX - size.width / 2).rounded(), visible.minX), visible.maxX - size.width),
                      y: min(max(window.frame.maxY - size.height, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private func resizeWindow(_ window: NSWindow, to frame: NSRect, reduceMotion: Bool) {
        revision += 1
        let current = revision
        // Give SwiftUI a layout pass to release the expanded minimum width before shrinking.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.revision == current else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            window.setFrame(frame, display: true, animate: !reduceMotion)
            guard self.revision == current else { return }
            self.isResizing = false
            if !self.isCompact { self.expandedFrame = nil }
        }
    }
}

/// Locates the device stage in desktop coordinates before compacting the window.
struct WindowStageReader: NSViewRepresentable {
    let onStage: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onStage(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
