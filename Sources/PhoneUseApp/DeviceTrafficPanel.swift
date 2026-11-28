import AppKit
import PhoneUseKit
import SwiftUI

/// Mirrors a physical device's live connection table from its worker by revision cursor.
@MainActor
final class DeviceTrafficSession: ObservableObject {
    typealias Transport = @Sendable (DeviceSummary, DeviceTrafficAction, Int) async throws -> DeviceTrafficSnapshot

    static let limit = 1000

    /// Newest connection first.
    @Published private(set) var flows: [DeviceTrafficFlow] = []
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var packets = 0
    @Published private(set) var status = ""
    private(set) var device: DeviceSummary?
    private var session: String?
    private var cursor = 0
    private var storage: [Int: DeviceTrafficFlow] = [:]
    private var polling: Task<Void, Never>?
    private let transport: Transport
    private let interval: Duration

    init(interval: Duration = .seconds(1),
         transport: @escaping Transport = { device, action, cursor in try await device.trafficCapture(action, after: cursor) }) {
        self.interval = interval
        self.transport = transport
    }

    /// Shows a capture that is still running in the device worker, for example after switching panels.
    func attach(_ device: DeviceSummary) async {
        guard self.device?.id != device.id else { return }
        reset(for: device)
        await perform(.read, on: device)
    }

    func start() { run(.start) }
    func stop() { run(.stop) }

    func clear() {
        if device != nil { run(.clear) }
    }

    /// Ends the capture of the previous device when the selection changes or the window closes.
    /// Passing the newly selected device keeps a session the panel already attached to it.
    func endSelection(except current: String? = nil) {
        guard device?.id != current || current == nil else { return }
        if running, let device {
            let transport = transport
            Task { _ = try? await transport(device, .stop, 0) }
        }
        reset(for: nil)
    }

    private func run(_ action: DeviceTrafficAction) {
        guard let device, !busy else { return }
        Task { await perform(action, on: device) }
    }

    private func perform(_ action: DeviceTrafficAction, on device: DeviceSummary) async {
        busy = true
        defer { busy = false }
        do {
            let snapshot = try await transport(device, action, action == .read || action == .stop ? cursor : 0)
            guard self.device?.id == device.id else { return }
            apply(snapshot)
            if snapshot.running { poll(device) }
        } catch {
            guard self.device?.id == device.id else { return }
            status = error.localizedDescription
        }
    }

    private func poll(_ device: DeviceSummary) {
        guard polling == nil else { return }
        polling = Task { [weak self, transport, interval] in
            while !Task.isCancelled {
                guard let cursor = self?.cursor else { return }
                do {
                    let snapshot = try await transport(device, .read, cursor)
                    guard let self, !Task.isCancelled, self.device?.id == device.id else { return }
                    self.apply(snapshot)
                    if !snapshot.running { break }
                    if snapshot.hasMore { continue }
                } catch {
                    guard let self, !Task.isCancelled, self.device?.id == device.id else { return }
                    self.running = false
                    self.status = error.localizedDescription
                    break
                }
                try? await Task.sleep(for: interval)
            }
            self?.polling = nil
        }
    }

    func apply(_ snapshot: DeviceTrafficSnapshot) {
        if snapshot.session != session {
            session = snapshot.session
            storage.removeAll()
        }
        for flow in snapshot.flows { storage[flow.id] = flow }
        var ordered = storage.values.sorted { $0.id > $1.id }
        if ordered.count > Self.limit {
            for flow in ordered[Self.limit...] { storage[flow.id] = nil }
            ordered.removeLast(ordered.count - Self.limit)
        }
        flows = ordered
        cursor = snapshot.nextCursor
        running = snapshot.running
        packets = snapshot.packets
        if let error = snapshot.error {
            status = error
        } else {
            status = snapshot.running ? "正在实时抓包" : (snapshot.packets > 0 ? "已停止" : "")
        }
    }

    private func reset(for device: DeviceSummary?) {
        polling?.cancel()
        polling = nil
        self.device = device
        session = nil
        cursor = 0
        storage.removeAll()
        flows = []
        running = false
        packets = 0
        status = ""
    }
}

/// Physical iPhone or iPad network tools: the live connection list and whole-device link conditions.
struct PhysicalNetworkPanel: View {
    enum Mode: Hashable { case traffic, condition }

    @ObservedObject var traffic: DeviceTrafficSession
    let device: DeviceSummary
    @State private var mode = Mode.traffic

    var body: some View {
        VStack(spacing: 0) {
            Picker("网络工具", selection: $mode) {
                Text("实时连接").tag(Mode.traffic)
                Text("整机弱网").tag(Mode.condition)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 10)
            switch mode {
            case .traffic: DeviceTrafficView(traffic: traffic, device: device)
            case .condition: PhysicalNetworkConditionPanel(device: device)
            }
        }
    }
}

private struct DeviceTrafficView: View {
    @ObservedObject var traffic: DeviceTrafficSession
    let device: DeviceSummary
    @State private var query = ""

    private var visible: [DeviceTrafficFlow] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return traffic.flows }
        return traffic.flows.filter { flow in
            [flow.process, flow.app ?? "", flow.host ?? "", flow.remote, flow.kind, flow.interface]
                .contains { $0.lowercased().contains(needle) }
                || flow.requests.contains { $0.url.lowercased().contains(needle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(traffic.running ? "停止抓包" : "开始抓包") {
                    traffic.running ? traffic.stop() : traffic.start()
                }
                .disabled(traffic.busy || traffic.device?.id != device.id)
                TextField("过滤 App、域名、IP 或 URL", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("清空") { traffic.clear() }
                    .disabled(traffic.busy || traffic.flows.isEmpty)
            }
            Text("通过 USB 读取设备的系统抓包服务，列出所有 App 的连接，无需修改 App。HTTPS 只显示域名和流量，明文 HTTP 显示请求 URL 与状态码。")
                .font(.caption).foregroundStyle(.secondary)
            if !traffic.status.isEmpty {
                Text(traffic.packets > 0 ? "\(traffic.status) · \(traffic.packets) 个包 · \(traffic.flows.count) 条连接" : traffic.status)
                    .font(.callout).textSelection(.enabled)
            }
            Divider()
            if traffic.flows.isEmpty {
                ContentUnavailableView("暂无连接", systemImage: "network",
                                       description: Text("开始抓包后，设备上新的网络活动会实时出现在这里。"))
            } else {
                List(visible) { DeviceTrafficRow(flow: $0) }
            }
        }
        .padding(10)
        .task(id: device.id) { await traffic.attach(device) }
    }
}

private struct DeviceTrafficRow: View {
    let flow: DeviceTrafficFlow

    private var owner: String {
        if let app = flow.app { return "\(app)（\(flow.process)）" }
        return flow.process.isEmpty ? "未知进程" : flow.process
    }

    private var destination: String {
        let address = flow.remote.contains(":") ? "[\(flow.remote)]" : flow.remote
        return "\(flow.host ?? address):\(flow.remotePort)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(owner).bold().lineLimit(1)
                Text(flow.kind.uppercased()).foregroundStyle(.secondary)
                Spacer()
                Text("↑ \(Self.bytes(flow.sent))  ↓ \(Self.bytes(flow.received))").monospacedDigit()
            }
            Text(destination).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            ForEach(Array(flow.requests.suffix(5).enumerated()), id: \.offset) { _, request in
                Text("\(request.method) \(request.url)  \(request.status.map(String.init) ?? "…")")
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            Text([Date(timeIntervalSince1970: flow.firstSeen).formatted(date: .omitted, time: .standard),
                  flow.host == nil ? nil : flow.remote, flow.interface, "\(flow.packets) 个包",
                  flow.closed ? "已结束" : nil].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .contextMenu {
            Button("复制目标地址") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(destination, forType: .string)
            }
        }
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }
}
