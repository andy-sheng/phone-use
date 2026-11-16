import AppKit
import SwiftUI
import XCTest
@testable import PhoneUseUI

@MainActor
final class WorkspaceLayoutTests: XCTestCase {
    func testSidebarAndWindowResizingKeepPanesAndPortraitPreviewInsideWindow() throws {
        try checkResizing(screenAspectRatio: 393.0 / 852.0)
    }

    func testSidebarAndWindowResizingKeepLandscapePreviewInsideWindow() throws {
        try checkResizing(screenAspectRatio: 852.0 / 393.0)
    }

    private func checkResizing(screenAspectRatio: CGFloat) throws {
        _ = NSApplication.shared
        let sidebar = NSView()
        let panel = NSView()
        let screenLayer = CALayer()
        var fixture = LayoutFixture(showsPanel: true, screenAspectRatio: screenAspectRatio,
                                    sidebar: sidebar, panel: panel, screenLayer: screenLayer)
        let host = NSHostingView(rootView: fixture)

        // Reuse the same hierarchy across panel toggles and shrinking back to the minimum
        // window size, as a retained divider position used to expand the entire navigation view.
        for showsPanel in [true, false, true] {
            fixture.showsPanel = showsPanel
            host.rootView = fixture
            for size in [CGSize(width: 1280, height: 920), CGSize(width: 940, height: 680),
                         CGSize(width: 1800, height: 1000), CGSize(width: 940, height: 680)] {
                host.frame.size = size
                layout(host)
                let navigation = try XCTUnwrap(splitViews(in: host).first)
                for sidebarWidth: CGFloat in [250, 480, 620, 220] {
                    navigation.setPosition(sidebarWidth, ofDividerAt: 0)
                    layout(host)

                    let splits = splitViews(in: host)
                    let context = "window=\(size), sidebar=\(sidebarWidth), panel=\(showsPanel), dividers=\(splits.map(\.dividerThickness))"
                    // Only the sidebar is a split; the panel floats over the stage.
                    XCTAssertEqual(splits.count, 1, context)
                    for split in splits {
                        assertContained(split.convert(split.bounds, to: host), in: host.bounds, context)
                    }
                    XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1, context)

                    let surface = try XCTUnwrap(screenSurface(in: host))
                    let screenRect = surface.convert(surface.bounds, to: host)
                    assertContained(screenRect, in: host.bounds, context)
                    XCTAssertGreaterThan(screenRect.width, 0, context)
                    XCTAssertGreaterThan(screenRect.height, 0, context)
                    // AppKit rounds both dimensions to pixel boundaries independently.
                    XCTAssertEqual(screenRect.width, screenRect.height * screenAspectRatio,
                                   accuracy: 1 + screenAspectRatio, context)
                    let sidebarRect = sidebar.convert(sidebar.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(screenRect.minX, sidebarRect.maxX, context)
                    if showsPanel {
                        let panelRect = panel.convert(panel.bounds, to: host)
                        assertContained(panelRect, in: host.bounds, context)
                        XCTAssertGreaterThanOrEqual(panelRect.width, 340, context)
                        XCTAssertLessThanOrEqual(screenRect.maxX, panelRect.minX, context)
                    }
                }
            }
        }
    }

    private func layout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        host.layoutSubtreeIfNeeded()
    }

    private func splitViews(in view: NSView) -> [NSSplitView] {
        let current = (view as? NSSplitView).map { [$0] } ?? []
        return current + view.subviews.flatMap { splitViews(in: $0) }
    }

    private func screenSurface(in view: NSView) -> ScreenSurface.SurfaceNSView? {
        if let surface = view as? ScreenSurface.SurfaceNSView { return surface }
        return view.subviews.lazy.compactMap { self.screenSurface(in: $0) }.first
    }

    private func assertContained(_ rect: CGRect, in bounds: CGRect, _ context: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - 1, context, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - 1, context, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 1, context, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 1, context, file: file, line: line)
    }
}

private struct LayoutFixture: View {
    var showsPanel: Bool
    let screenAspectRatio: CGFloat
    let sidebar: NSView
    let panel: NSView
    let screenLayer: CALayer

    var body: some View {
        DeviceWorkspaceView(showsPanel: showsPanel) {
            List { Text("NX732J") }
                .background(LayoutProbe(view: sidebar))
        } detail: {
            DeviceFrame(screenAspectRatio: screenAspectRatio) {
                ScreenSurface(screenLayer: screenLayer, acceptsInput: false,
                              onTouch: { _, _ in }, onFlick: { _, _ in })
            }
            .padding(.top, 52)
            .padding(.bottom, 84)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } panel: {
            Color.clear.background(LayoutProbe(view: panel))
        }
    }
}

private struct LayoutProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}
