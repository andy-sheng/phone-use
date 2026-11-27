import AppKit
import PhoneUseUI
import SwiftUI

/// Owns one hosting view so moving the panel also moves the live WebKit view and its connection.
@MainActor
final class WebInspectorWindow: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isDetached = false
    private var host: NSView?
    private weak var dock: NSView?
    private var window: NSWindow?
    private var revealDock: (() -> Void)?

    func mount(in dock: NSView, revealDock: @escaping () -> Void, makeHost: () -> NSView) {
        self.dock = dock
        self.revealDock = revealDock
        if host == nil { host = makeHost() }
        if !isDetached { moveHost(to: dock) }
    }

    func unmount(from dock: NSView) {
        guard self.dock === dock else { return }
        self.dock = nil
        if !isDetached {
            host?.removeFromSuperview()
            host = nil
            revealDock = nil
        }
    }

    private func moveHost(to container: NSView) {
        guard let host, host.superview !== container else { return }
        host.removeFromSuperview()
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
    }

    func detach() {
        guard let host, window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "网页调试"
        window.minSize = NSSize(width: 460, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PhoneUseWebInspector")
        window.delegate = self
        self.window = window
        let responder = host.window?.firstResponder as? NSView
        if let container = window.contentView { moveHost(to: container) }
        isDetached = true
        show()
        if let responder, responder.isDescendant(of: host) { window.makeFirstResponder(responder) }
    }

    func show() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func redock() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
        isDetached = false
        if let dock { moveHost(to: dock) }
        revealDock?()
    }
}

private struct WebInspectorContent: View {
    @ObservedObject var model: DeviceListModel
    @ObservedObject var presentation: WebInspectorWindow

    var body: some View {
        let device = model.selectedDevice
        let supported = device?.isReady == true && device?.isSimulator == false && device?.isAndroid == false
        WebInspectorPanel(device: supported ? device : nil, detached: presentation.isDetached) {
            if presentation.isDetached { presentation.redock() } else { presentation.detach() }
        }
        .id(supported ? device?.udid : nil)
    }
}

struct WebInspectorDock: NSViewRepresentable {
    let presentation: WebInspectorWindow
    let model: DeviceListModel
    let revealDock: () -> Void

    func makeCoordinator() -> WebInspectorWindow { presentation }

    func makeNSView(context: Context) -> NSView {
        let dock = NSView()
        presentation.mount(in: dock, revealDock: revealDock) {
            let view = NSHostingView(rootView: WebInspectorContent(model: model, presentation: presentation))
            view.sizingOptions = []
            return view
        }
        return dock
    }

    func updateNSView(_ dock: NSView, context: Context) {}

    static func dismantleNSView(_ dock: NSView, coordinator: WebInspectorWindow) {
        coordinator.unmount(from: dock)
    }
}
