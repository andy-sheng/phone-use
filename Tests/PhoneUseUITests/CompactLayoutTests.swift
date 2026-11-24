import AppKit
import SwiftUI
import XCTest
@testable import PhoneUseUI

@MainActor
final class CompactLayoutTests: XCTestCase {
    private let chrome: CGFloat = 52

    func testPortraitPhoneFitsSnuglyAndCapsFrameLength() {
        let ratio: CGFloat = 393.0 / 852.0
        let stage = CompactLayout.stageSize(screenAspectRatio: ratio,
                                            available: CGSize(width: 1728, height: 1080), chromeHeight: chrome)
        let frame = frameSize(in: stage)
        XCTAssertEqual(frame.height, CompactLayout.maximumFrameLength, accuracy: 1)
        XCTAssertEqual(frame.width / frame.height,
                       DeviceFrame<EmptyView>.outerAspectRatio(screenAspectRatio: ratio), accuracy: 0.01)
        XCTAssertLessThan(stage.width, 500)
    }

    func testRotatingTheDeviceKeepsTheSameBezelThicknessAtActualSize() {
        let portrait = DeviceFrame<EmptyView>.outerSize(screenWidth: 393, screenAspectRatio: 393.0 / 852)
        let landscape = DeviceFrame<EmptyView>.outerSize(screenWidth: 852, screenAspectRatio: 852.0 / 393)
        XCTAssertEqual(portrait.width, landscape.height, accuracy: 0.001)
        XCTAssertEqual(portrait.height, landscape.width, accuracy: 0.001)
        XCTAssertEqual(landscape.width - 852, landscape.height - 393, accuracy: 0.001)
    }

    func testSmallScreenKeepsWindowOnScreen() {
        let available = CGSize(width: 1280, height: 700)
        let stage = CompactLayout.stageSize(screenAspectRatio: 393.0 / 852.0, available: available, chromeHeight: chrome)
        XCTAssertLessThanOrEqual(stage.height + chrome, available.height * CompactLayout.screenFraction + 1)
        XCTAssertGreaterThanOrEqual(stage.width, CompactLayout.minimumSize.width)
    }

    func testLandscapeIsLimitedByWidth() {
        let ratio: CGFloat = 852.0 / 393.0
        let available = CGSize(width: 900, height: 1080)
        let stage = CompactLayout.stageSize(screenAspectRatio: ratio, available: available, chromeHeight: chrome)
        let frame = frameSize(in: stage)
        XCTAssertLessThanOrEqual(stage.width, available.width * CompactLayout.screenFraction + 1)
        XCTAssertLessThanOrEqual(frame.width, CompactLayout.maximumFrameLength + 1)
        XCTAssertEqual(frame.width / frame.height,
                       DeviceFrame<EmptyView>.outerAspectRatio(screenAspectRatio: ratio), accuracy: 0.02)
    }

    func testWindowClosesAroundStageAndRestoresFrameWithoutReplacingSurface() async throws {
        _ = NSApplication.shared
        let controller = CompactWindowController()
        let layer = CALayer()
        let host = NSHostingController(rootView: CompactFixture(controller: controller, layer: layer))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 1040, height: 720))
        window.toolbar = NSToolbar(identifier: "CompactLayoutTests")
        window.title = "Test Device"
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .line
        window.center()
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(550))
        window.contentView?.layoutSubtreeIfNeeded()

        let originalBackground = window.backgroundColor
        let originalFullSizeContent = window.styleMask.contains(.fullSizeContentView)
        let original = window.frame
        let stage = try XCTUnwrap(controller.stage)
        let originalCenter = window.convertToScreen(stage.convert(stage.bounds, to: nil)).midX
        let surface = try XCTUnwrap(layer.superlayer)
        let ratio: CGFloat = 393.0 / 852.0
        for reduceMotion in [false, true] {
            window.appearance = NSAppearance(named: reduceMotion ? .aqua : .darkAqua)
            controller.setCompact(true, screenAspectRatio: ratio, reduceMotion: reduceMotion)
            try await waitForResize(controller)
            XCTAssertLessThan(window.frame.width, original.width)
            let visible = try XCTUnwrap(window.screen?.visibleFrame)
            let halfWidth = window.frame.width / 2
            XCTAssertEqual(window.frame.midX, min(max(originalCenter, visible.minX + halfWidth),
                                                 visible.maxX - halfWidth), accuracy: 2)
            XCTAssertEqual(stage.bounds.width, window.contentLayoutRect.width, accuracy: 2)
            XCTAssertTrue(layer.superlayer === surface)

            for focused in [true, false] {
                if focused { window.makeKey() } else { window.resignKey() }
                window.displayIfNeeded()
                try assertContinuousWindowBackground(window)
                XCTAssertTrue(window.titlebarAppearsTransparent)
                XCTAssertEqual(window.titlebarSeparatorStyle, .none)
                XCTAssertEqual(window.backgroundColor, .underPageBackgroundColor)
                XCTAssertTrue(window.toolbar?.isVisible == true)
                XCTAssertEqual(window.title, "Test Device")
            }

            controller.setCompact(false, screenAspectRatio: ratio, reduceMotion: reduceMotion)
            try await waitForResize(controller)
            XCTAssertEqual(window.styleMask.contains(.fullSizeContentView), originalFullSizeContent)
            XCTAssertFalse(window.titlebarAppearsTransparent)
            XCTAssertEqual(window.titlebarSeparatorStyle, .line)
            XCTAssertEqual(window.backgroundColor, originalBackground)
            XCTAssertEqual(window.frame, original)
            XCTAssertTrue(layer.superlayer === surface)
            XCTAssertEqual(window.convertToScreen(stage.convert(stage.bounds, to: nil)).midX,
                           originalCenter, accuracy: 2)
        }

        controller.setCompact(true, screenAspectRatio: ratio, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(80))
        controller.setCompact(false, screenAspectRatio: ratio, reduceMotion: false)
        try await waitForResize(controller)
        XCTAssertEqual(window.frame, original)
        XCTAssertFalse(controller.isCompact)
    }

    private func assertContinuousWindowBackground(_ window: NSWindow) throws {
        let frame = try XCTUnwrap(window.contentView?.superview)
        let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / frame.bounds.width
        // Sample the margin beside the device and the same column at both ends of the window.
        let x = Int(8 * scale)
        let inset = Int(24 * scale)
        let stage = try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        for y in [inset, bitmap.pixelsHigh - 1 - inset] {
            let edge = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            XCTAssertEqual(edge.redComponent, stage.redComponent, accuracy: 2.0 / 255)
            XCTAssertEqual(edge.greenComponent, stage.greenComponent, accuracy: 2.0 / 255)
            XCTAssertEqual(edge.blueComponent, stage.blueComponent, accuracy: 2.0 / 255)
            XCTAssertEqual(edge.alphaComponent, 1, accuracy: 0.01)
        }
    }

    private func waitForResize(_ controller: CompactWindowController) async throws {
        let timeout = ContinuousClock.now + .seconds(3)
        while controller.isResizing, ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(controller.isResizing)
        // Allow the split view to finish its own layout pass.
        try await Task.sleep(for: .milliseconds(550))
    }

    /// Switching layouts builds the new surface before the old one is dismantled; the old one
    /// must not pull the shared stream layer back out of the new surface.
    func testOldSurfaceDoesNotTakeBackAdoptedLayer() {
        let screenLayer = CALayer()
        let full = ScreenSurface.SurfaceNSView()
        let compact = ScreenSurface.SurfaceNSView()
        full.hostedLayer = screenLayer
        compact.hostedLayer = screenLayer
        full.hostedLayer = nil
        XCTAssertTrue(screenLayer.superlayer === compact.layer)
    }

    private func frameSize(in stage: CGSize) -> CGSize {
        let insets = CompactLayout.screenInsets
        return CGSize(width: stage.width - insets.leading - insets.trailing,
                      height: stage.height - insets.top - insets.bottom - CompactLayout.controlsHeight)
    }
}

private struct CompactFixture: View {
    @ObservedObject var controller: CompactWindowController
    let layer: CALayer

    var body: some View {
        DeviceWorkspaceView(isCompact: controller.isCompact, isResizingWindow: controller.isResizing,
                            showsPanel: !controller.isCompact) {
            List { Text("Device") }
        } detail: {
            ZStack {
                Color(nsColor: .underPageBackgroundColor).ignoresSafeArea()
                ScreenSurface(screenLayer: layer, acceptsInput: false, onTouch: { _, _ in })
                    .padding(16)
            }
            .background(WindowStageReader { controller.stage = $0 })
        } panel: {
            Text("Inspector")
        }
    }
}
