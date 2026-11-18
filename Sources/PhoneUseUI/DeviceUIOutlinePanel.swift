import AppKit
import PhoneUseKit
import SwiftUI

/// One request at a time. Late results from a hidden panel or an old selection cannot replace
/// the active device's outline, even when the underlying accessibility request is not cancellable.
@MainActor
final class UIOutlineModel: ObservableObject {
    @Published private(set) var outline = ""
    @Published private(set) var error: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false
    private var deviceID: String?
    private var generation = UUID()
    private let interval: Duration

    init(interval: Duration = .seconds(1)) { self.interval = interval }

    func stop(clear: Bool) {
        generation = UUID()
        isRefreshing = false
        if clear {
            deviceID = nil
            outline = ""
            error = nil
            updatedAt = nil
        }
    }

    func run(deviceID: String, pollInterval: Duration? = nil, read: @MainActor () async throws -> UITree?) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        if self.deviceID != deviceID {
            outline = ""
            error = nil
            updatedAt = nil
        }
        self.deviceID = deviceID
        defer { if generation == token { isRefreshing = false } }
        while generation == token && !Task.isCancelled {
            isRefreshing = true
            do {
                let tree = try await read()
                guard generation == token, !Task.isCancelled else { return }
                if let tree {
                    let text = tree.outline
                    if outline != text { outline = text }
                    error = nil
                    updatedAt = Date()
                } else {
                    outline = ""
                    updatedAt = nil
                    error = "设备连接已结束，请重新连接。"
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                self.error = String(describing: error)
            }
            isRefreshing = false
            let normalInterval = pollInterval ?? interval
            let delay = error != nil && pollInterval != nil ? max(normalInterval, .seconds(5)) : normalInterval
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }
}

/// A live, selectable copy of the same outline returned by the describe_ui MCP tool.
public struct DeviceUIOutlinePanel: View {
    private let device: DeviceSummary?
    @ObservedObject private var screen: ScreenModel
    @StateObject private var model = UIOutlineModel()
    @State private var isPaused = false
    @State private var refreshGeneration = 0

    public init(device: DeviceSummary?, screen: ScreenModel) {
        self.device = device
        self.screen = screen
    }

    private var supportsOutline: Bool { device.map { !$0.isAndroid } ?? false }

    private var isConnected: Bool {
        guard let device else { return false }
        return device.isReady && screen.isShowingDevice(device.id) && screen.stream != nil
    }

    private var pollingKey: String {
        "\(device?.id ?? "")|\(isConnected)|\(isPaused)|\(refreshGeneration)"
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("describe_ui").font(.headline.monospaced())
                    Text(!supportsOutline || !isConnected ? "等待可用的 iOS 连接" : isPaused ? "已暂停" : (device?.isSimulator == true ? "实时刷新 · 间隔 1 秒" : "实时刷新 · 间隔 3 秒"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { isPaused.toggle() } label: {
                    Label(isPaused ? "继续刷新" : "暂停刷新", systemImage: isPaused ? "play.fill" : "pause.fill")
                }
                .help(isPaused ? "继续刷新" : "暂停刷新")
                .disabled(!isConnected || !supportsOutline)
                Button { refreshGeneration += 1 } label: { Label("立即刷新", systemImage: "arrow.clockwise") }
                    .help("立即刷新")
                    .disabled(isPaused || !isConnected || !supportsOutline || model.isRefreshing)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.outline, forType: .string)
                } label: { Label("复制界面结构", systemImage: "doc.on.doc") }
                .help("复制界面结构")
                .disabled(model.outline.isEmpty)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(16)
            Divider()
            content
            if let updatedAt = model.updatedAt {
                Divider()
                HStack {
                    Text(model.error == nil ? "更新于" : "上次成功更新")
                    Text(updatedAt, format: .dateTime.hour().minute().second())
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
        .task(id: pollingKey) {
            guard let device, supportsOutline, isConnected, !isPaused else {
                model.stop(clear: !isPaused || !isConnected || !supportsOutline)
                return
            }
            await model.run(deviceID: device.id, pollInterval: device.isSimulator ? .seconds(1) : .seconds(3)) { try await screen.uiTree(for: device.id) }
        }
        .onDisappear { model.stop(clear: true) }
    }

    @ViewBuilder
    private var content: some View {
        if device == nil {
            ContentUnavailableView("未选择设备", systemImage: "iphone")
        } else if !supportsOutline {
            ContentUnavailableView("此设备暂不支持界面结构", systemImage: "list.bullet.indent",
                                   description: Text("describe_ui 支持 iOS；真机需要开发签名应用。"))
        } else if !isConnected {
            ContentUnavailableView("连接后查看界面结构", systemImage: "link",
                                   description: Text("开始查看设备屏幕后自动刷新。"))
        } else {
            VStack(spacing: 0) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                if model.outline.isEmpty {
                    if isPaused {
                        ContentUnavailableView("刷新已暂停", systemImage: "pause.circle")
                    } else if model.error == nil {
                        ProgressView("正在读取界面结构…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { Spacer() }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(model.outline)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                }
            }
        }
    }
}
