import AppKit
import PhoneUseKit
import SwiftUI
import WebKit

// These WebKit SPI are loaded at runtime so other panels still work on a system
// that changes its remote inspector. The controller supplies the real InspectorFrontendHost.
@objc private protocol RemoteInspectorSPI {
    @objc(initWithConfiguration:) init(configuration: NSObject)
    var delegate: NSObject? { get set }
    var webView: WKWebView? { get }
    var window: NSWindow? { get }
    @objc(loadForDebuggable:backendCommandsURL:) func load(_ target: NSObject, commands: NSURL)
    func sendMessageToFrontend(_ message: String)
    func close()
}

private struct FrontendEndpoint: Decodable {
    let kind: String
    let commands: String
}

private struct InspectorError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct WebInspectorFrontend: NSViewRepresentable {
    let device: DeviceSummary
    let pageID: String
    var chrome = false
    let status: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.start(device: device, pageID: pageID, chrome: chrome, container: container, status: status)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject {
        private var controller: RemoteInspectorSPI?
        private var chromeHost: ChromeInspectorHost?
        private var stream: ByteStream?
        private var connection: Task<Void, Never>?
        private var sender: Task<Void, Never>?
        private var outgoing: AsyncStream<String>.Continuation?
        private var report: ((String?) -> Void)?

        func start(device: DeviceSummary, pageID: String, chrome: Bool, container: NSView, status: @escaping (String?) -> Void) {
            report = status
            connection = Task { [self] in
                do {
                    let data = try await DeviceHub.shared.daemon().webInspector(device.udid, .frontend(page: pageID, chrome: chrome))
                    struct SocketEndpoint: Decodable { let socket: String }
                    let path = try JSONDecoder().decode(SocketEndpoint.self, from: data).socket
                    let socket = ByteStream(unixSocket: path)
                    defer { socket.close() }
                    try await socket.open()
                    try Task.checkCancellation()
                    stream = socket
                    let (messages, continuation) = AsyncStream<String>.makeStream()
                    outgoing = continuation
                    sender = Task {
                        do {
                            for await message in messages {
                                try await socket.write(Data((message + "\n").utf8))
                            }
                        } catch { socket.close() }
                    }
                    if chrome {
                        struct ChromeEndpoint: Decodable { let url: URL }
                        let entry = try JSONDecoder().decode(ChromeEndpoint.self, from: data).url
                        guard entry.scheme == "https", entry.host == "chrome-devtools-frontend.appspot.com",
                              entry.path.hasPrefix("/serve_rev/@") else { throw InspectorError("Chrome DevTools 入口无效。") }
                        let host = ChromeInspectorHost(entry: entry, send: { continuation.yield($0) }) { [weak self] message in
                            self?.report?(message)
                            self?.stop()
                        }
                        chromeHost = host
                        host.view.frame = container.bounds
                        host.view.autoresizingMask = [.width, .height]
                        container.addSubview(host.view)
                        for await _ in host.ready { break }
                        try Task.checkCancellation()
                    } else {
                        try embed(JSONDecoder().decode(FrontendEndpoint.self, from: data), device: device, in: container)
                    }
                    status(nil)
                    while !Task.isCancelled {
                        let data = try await socket.readLine()
                        try Task.checkCancellation()
                        let message = String(decoding: data, as: UTF8.self)
                        if let chromeHost { try await chromeHost.deliver(message) }
                        else { controller?.sendMessageToFrontend(message) }
                    }
                } catch {
                    if !Task.isCancelled {
                        report?((error as? DeviceHubError)?.description ?? error.localizedDescription)
                    }
                }
                stop()
            }
        }

        private func embed(_ endpoint: FrontendEndpoint, device: DeviceSummary, in container: NSView) throws {
            guard let type = NSClassFromString("_WKRemoteWebInspectorViewController"),
                  let configuration = NSClassFromString("_WKInspectorConfiguration") as? NSObject.Type,
                  let info = NSClassFromString("_WKInspectorDebuggableInfo") as? NSObject.Type,
                  ["initWithConfiguration:", "loadForDebuggable:backendCommandsURL:", "setDelegate:",
                   "window", "webView", "sendMessageToFrontend:", "close"].allSatisfy({
                      class_getInstanceMethod(type, NSSelectorFromString($0)) != nil
                  }) else { throw InspectorError("当前 macOS 的 WebKit 无法提供远程网页检查器。") }

            let target = info.init()
            let kinds = ["itml", "javascript", "service-worker", "page", "web-page"]
            guard let kind = kinds.firstIndex(of: endpoint.kind),
                  let url = URL(string: "inspector-resource:///" + endpoint.commands) else {
                throw InspectorError("当前 WebKit 无法识别此页面的调试协议。")
            }
            let properties: [String: Any] = ["debuggableType": kind, "targetPlatformName": "iOS",
                                             "targetProductVersion": device.productVersion ?? "",
                                             "targetBuildVersion": device.buildVersion ?? "", "targetIsSimulator": false]
            for (key, value) in properties {
                guard target.responds(to: NSSelectorFromString("set" + key.prefix(1).uppercased() + key.dropFirst() + ":"))
                else { throw InspectorError("当前 macOS 的 WebKit 缺少目标属性 " + key) }
                target.setValue(value, forKey: key)
            }
            let inspector = unsafeBitCast(type, to: RemoteInspectorSPI.Type.self).init(configuration: configuration.init())
            controller = inspector
            inspector.delegate = self
            inspector.load(target, commands: url as NSURL)
            guard let webView = inspector.webView else { throw InspectorError("WebKit 未能创建网页检查器视图。") }
            // WebKit creates a standalone window for Safari. Keep its frontend in the workspace.
            inspector.window?.alphaValue = 0
            inspector.window?.ignoresMouseEvents = true
            inspector.window?.isExcludedFromWindowsMenu = true
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
            if let window = inspector.window {
                NotificationCenter.default.addObserver(self, selector: #selector(returnFocus(_:)),
                                                       name: NSWindow.didBecomeKeyNotification, object: window)
            }
        }

        @objc private func returnFocus(_ note: Notification) {
            (note.object as? NSWindow)?.orderOut(nil)
            controller?.webView?.window?.makeKey()
        }

        @objc(inspectorViewController:sendMessageToBackend:)
        func inspector(_ inspector: NSObject, send message: String) { outgoing?.yield(message) }

        @objc(inspectorViewControllerInspectorDidClose:)
        func inspectorClosed(_ inspector: NSObject) {
            report?("网页检查器已关闭。")
            stop()
        }

        func stop() {
            report = nil
            connection?.cancel()
            connection = nil
            outgoing?.finish()
            outgoing = nil
            sender?.cancel()
            sender = nil
            stream?.close()
            stream = nil
            NotificationCenter.default.removeObserver(self)
            chromeHost?.close()
            chromeHost = nil
            controller?.delegate = nil
            controller?.webView?.removeFromSuperview()
            controller?.close()
            controller = nil
        }
    }
}
