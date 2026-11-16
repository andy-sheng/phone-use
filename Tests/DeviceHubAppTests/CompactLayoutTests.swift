import AppKit
import SwiftUI
import XCTest
@testable import DeviceHubApp

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
