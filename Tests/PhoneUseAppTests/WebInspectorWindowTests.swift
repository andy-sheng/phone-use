import AppKit
import SwiftUI
import XCTest
@testable import PhoneUseApp

@MainActor
final class WebInspectorWindowTests: XCTestCase {
    func testDetachingAndClosingPreserveHostedViewAndFrontendCoordinator() async throws {
        _ = NSApplication.shared
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                            styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.orderBack(nil)
        defer { main.close() }

        let dock = try XCTUnwrap(main.contentView)
        let presentation = WebInspectorWindow()
        let probe = Lifetime()
        let host = NSHostingView(rootView: FrontendProbe(lifetime: probe))
        var docks = 0
        func mount() {
            presentation.mount(in: dock, revealDock: { docks += 1 }) {
                XCTAssertEqual(docks, 0, "Redocking must reuse the original hosting view")
                return host
            }
        }
        mount()
        host.layoutSubtreeIfNeeded()
        let original = try XCTUnwrap(probe.view)
        for useCloseButton in [false, true] {
            presentation.detach()
            let window = try XCTUnwrap(host.window)
            XCTAssertFalse(window === main)
            XCTAssertTrue(presentation.isDetached)
            presentation.unmount(from: dock)
            presentation.show()
            try await Task.sleep(for: .milliseconds(100))
            if useCloseButton { window.performClose(nil) } else { presentation.redock() }
            mount()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(presentation.isDetached)
            XCTAssertTrue(original.window === main)
            XCTAssertTrue(original === probe.view)
            XCTAssertEqual(probe.dismantles, 0)
        }
        XCTAssertEqual(docks, 2)
        presentation.unmount(from: dock)
    }

    private final class Lifetime {
        weak var view: NSView?
        var dismantles = 0
    }

    private struct FrontendProbe: NSViewRepresentable {
        let lifetime: Lifetime
        func makeCoordinator() -> Lifetime { lifetime }
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            lifetime.view = view
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
        static func dismantleNSView(_ nsView: NSView, coordinator: Lifetime) { coordinator.dismantles += 1 }
    }
}
