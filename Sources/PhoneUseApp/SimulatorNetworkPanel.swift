import AppKit
import PhoneUseKit
import PhoneUseUI
import SwiftUI

private func networkResource(_ name: String, _ ext: String) throws -> URL {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle.main
    #endif
    guard let url = bundle.url(forResource: name, withExtension: ext) else {
        throw DeviceHubError.serviceFailed("缺少网络调试资源 \(name).\(ext)")
    }
    return url
}

@MainActor
final class SimulatorNetworkSession: ObservableObject {
    struct Event: Decodable, Identifiable {
        let id = UUID()
        let event: String
        let method, url, message: String?
        let status, millis, sent, received: Int?
        enum CodingKeys: String, CodingKey { case event, method, url, message, status, millis, sent, received }
    }

    @Published private(set) var requests: [Event] = []
    @Published private(set) var status = ""
    @Published private(set) var active = false
    private var input: FileHandle?
    private var stopping = false
    private var attached = false

    func clear() { requests.removeAll() }

    func start(device: DeviceSummary, bundle: String, rate: Int) {
        guard !active, device.isSimulator, device.isReady else { return }
        guard bundle.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*/#) != nil else {
            status = "请输入有效的 Bundle ID"
            return
        }
        do {
            guard let python = DaemonLauncher.pythonExecutable else {
                throw DeviceHubError.serviceFailed("找不到 PhoneUse 的 Python 运行环境")
            }
            let process = Process()
            process.executableURL = python
            process.arguments = ["-I", "-B", try networkResource("phoneuse_network_debug", "py").path,
                                 device.deviceIdentifier, bundle, String(rate)]
            var environment = ProcessInfo.processInfo.environment
            environment["DEVELOPER_DIR"] = try SimulatorLifecycle.developerDirectory()
            process.environment = environment
            try launch(process, bundle: bundle)
        } catch { status = error.localizedDescription }
    }

    func launch(_ process: Process, bundle: String) throws {
        let control = Pipe(), events = Pipe()
        process.standardInput = control
        process.standardOutput = events
        try process.run()
        input = control.fileHandleForWriting
        active = true
        stopping = false
        attached = false
        clear()
        status = "正在重新启动 \(bundle)…"
        // A pipe can stay open for the entire session. Consume each available chunk
        // on a dedicated queue, including records smaller than a Foundation read buffer.
        DispatchQueue(label: "PhoneUse.network-events").async { [self] in
            let handle = events.fileHandleForReading
            var pending = Data()
            var failure: String?
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let record = pending[..<newline]
                    if let event = try? JSONDecoder().decode(Event.self, from: record) {
                        if event.event == "error" { failure = event.message }
                        DispatchQueue.main.async { if !self.stopping { self.receive(event) } }
                    }
                    pending.removeSubrange(...newline)
                }
            }
            process.waitUntilExit()
            let result = failure ?? (process.terminationStatus == 0 ? "已结束" : "网络调试进程意外退出")
            DispatchQueue.main.async {
                try? self.input?.close()
                self.input = nil
                self.status = result
                self.active = false
            }
        }
    }

    private func receive(_ event: Event) {
        switch event.event {
        case "launched":
            if !attached { status = "已启动，等待应用创建调试 URLSession…" }
        case "attached":
            attached = true
            status = "已连接，正在记录请求"
        case "request":
            requests.insert(event, at: 0)
            if requests.count > 300 { requests.removeLast() }
        default: break
        }
    }

    func stop() {
        guard active, !stopping else { return }
        stopping = true
        status = "正在结束并恢复应用网络…"
        try? input?.close()
        input = nil
    }

    func endSelection() {
        stop()
        clear()
        if !active { status = "" }
    }

    func exportClient() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PhoneUseNetworkDebug.swift"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(contentsOf: networkResource("PhoneUseNetworkDebug.swift", "txt")).write(to: destination, options: .atomic)
        } catch { status = error.localizedDescription }
    }
}

struct SimulatorNetworkPanel: View {
    @ObservedObject var monitor: SimulatorNetworkSession
    let device: DeviceSummary?
    @AppStorage("networkDebug.bundle") private var bundle = ""
    @AppStorage("networkDebug.rate") private var rate = 128

    var body: some View {
        if let device, device.isSimulator, device.isReady {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("应用 Bundle ID", text: $bundle)
                    Picker("上下行各限速", selection: $rate) {
                        Text("不限速").tag(0)
                        ForEach([32, 128, 512, 2048], id: \.self) { Text("\($0) KiB/s").tag($0) }
                    }.fixedSize()
                }.disabled(monitor.active)
                HStack {
                    Button(monitor.active ? "结束并重启应用" : "重启应用并开始") {
                        if monitor.active { monitor.stop() }
                        else { monitor.start(device: device, bundle: bundle.trimmingCharacters(in: .whitespacesAndNewlines), rate: rate) }
                    }
                    Button("导出接入文件") { monitor.exportClient() }
                    Spacer()
                    Button("清空") { monitor.clear() }.disabled(monitor.requests.isEmpty)
                }
                Text("iOS 17+ 调试构建：将接入文件加入应用，用 PhoneUseNetworkDebug.session() 创建要观察的 URLSession。")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !monitor.status.isEmpty { Text(monitor.status).font(.callout).textSelection(.enabled) }
                Divider()
                if monitor.requests.isEmpty {
                    ContentUnavailableView("暂无请求", systemImage: "network", description: Text("发起请求后，在这里查看已完成的传输。"))
                } else {
                    List(monitor.requests) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.method ?? "").bold()
                                Text(row.status == 0 ? "无 HTTP 响应" : "HTTP \(row.status ?? 0)")
                                Spacer()
                                Text("\(row.millis ?? 0) ms")
                            }
                            Text(row.url ?? "").textSelection(.enabled)
                            Text("上传 \(row.sent ?? 0) B · 下载 \(row.received ?? 0) B").foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }
            }.padding(10)
        } else {
            ContentUnavailableView("请选择已就绪的 iPhone、iPad 或 iOS 模拟器", systemImage: "network")
        }
    }
}
