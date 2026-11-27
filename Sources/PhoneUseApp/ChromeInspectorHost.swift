import WebKit

/// Chromium's frontend uses these two host hooks when embedded by a desktop app.
@MainActor
final class ChromeInspectorHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let view: WKWebView
    let ready: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let entry: URL
    private let send: (String) -> Void
    private let failed: (String) -> Void
    private var timeout: Task<Void, Never>?
    private var connected = false

    init(entry: URL, send: @escaping (String) -> Void, failed: @escaping (String) -> Void) {
        self.entry = entry
        self.send = send
        self.failed = failed
        (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: """
            // Let DevTools construct its full hosted implementation, including its
            // private settings and metrics state, then attach our native transport.
            Object.defineProperty(globalThis, "InspectorFrontendHost", {
                configurable: true,
                set(host) {
                    // Start each inspector session with the screencast closed.
                    if (localStorage.getItem("screencast-enabled") === null) {
                        localStorage.setItem("screencast-enabled", "false");
                    }
                    // WKWebView supplies prefers-color-scheme but not Chrome's devtools:// theme stylesheet.
                    localStorage.setItem("chrome-theme-colors", "false");
                    host.isHostedMode = () => false;
                    host.sendMessageToBackend = text => webkit.messageHandlers.phoneUseCDP.postMessage(text);
                    Object.defineProperty(globalThis, "InspectorFrontendHost", {value: host, configurable: true});
                }
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "phoneUseCDP")
        view.navigationDelegate = self
        view.load(URLRequest(url: entry))
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(50))
            guard !Task.isCancelled else { return }
            self?.failed("Chrome DevTools 加载超时。请检查网络，或断开后选择 WebKit。")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url == entry,
              let text = message.body as? String else { return }
        send(text)
        if !connected {
            connected = true
            timeout?.cancel()
            signal.yield(())
            signal.finish()
        }
    }

    func deliver(_ message: String) async throws {
        _ = try await view.callAsyncJavaScript("InspectorFrontendAPI.dispatchMessage(message); return true",
                                               arguments: ["message": message], in: nil, contentWorld: .page)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == entry ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed("Chrome DevTools 进程已退出。") }

    func close() {
        timeout?.cancel()
        signal.finish()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "phoneUseCDP")
        view.stopLoading()
        view.removeFromSuperview()
    }
}
