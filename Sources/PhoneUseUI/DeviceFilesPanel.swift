import AppKit
import PhoneUseKit
import SwiftUI

@MainActor
final class DeviceFilesModel: ObservableObject {
    @Published private(set) var apps: [SandboxApp] = []
    @Published private(set) var mounts: [SandboxMount] = []
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published var selection: String?
    private var volumes: (any SandboxVolumeAccess)?
    private var device: DeviceSummary?
    private var iconRequests = Set<String>()
    private var generation = UUID()
    private let makeFiles: (DeviceSummary) throws -> any DeviceFileAccess
    private let makeVolumes: (DeviceSummary) throws -> any SandboxVolumeAccess
    private let openFinder: (URL) -> Bool
    private let fetchIcon: (DeviceSummary, SandboxApp) async throws -> Data?

    init(makeFiles: @escaping (DeviceSummary) throws -> any DeviceFileAccess = { try DeviceFiles(device: $0) },
         makeVolumes: @escaping (DeviceSummary) throws -> any SandboxVolumeAccess = { try DeviceSandboxVolumes(device: $0) },
         openFinder: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         fetchIcon: @escaping (DeviceSummary, SandboxApp) async throws -> Data? = { try await DeviceAppIcons.png(device: $0, app: $1) }) {
        self.makeFiles = makeFiles
        self.makeVolumes = makeVolumes
        self.openFinder = openFinder
        self.fetchIcon = fetchIcon
    }

    var selectedApp: SandboxApp? { apps.first { $0.id == selection } }
    var selectedMount: SandboxMount? { mounts.first { $0.bundleID == selection } }

    var canOpen: Bool {
        guard let selectedApp else { return false }
        return device?.isAndroid != true || selectedApp.containerAccessible != false
    }

    func stop() { generation = UUID(); isBusy = false }

    func load(_ device: DeviceSummary) async {
        stop()
        let token = generation
        apps = []; mounts = []; selection = nil; volumes = nil; error = nil; isBusy = true
        self.device = device; icons = [:]; iconRequests = []
        defer { if token == generation { isBusy = false } }
        do {
            let files = try makeFiles(device)
            let volumes = try makeVolumes(device)
            async let listedApps = files.apps()
            async let listedMounts = volumes.mounts()
            let (apps, mounts) = try await (listedApps, listedMounts)
            guard token == generation, !Task.isCancelled else { return }
            self.volumes = volumes
            self.apps = apps.sorted {
                if ($0.containerAccessible == true) != ($1.containerAccessible == true) { return $0.containerAccessible == true }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            self.mounts = mounts
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            let hint = device.isAndroid ? "请确认设备已授权 ADB 调试。" : "请确认设备已解锁且 Xcode 能识别该设备。"
            self.error = "无法获取应用。\(hint)\n\(error)"
        }
    }

    func loadIcon(_ app: SandboxApp) async {
        guard let device, !device.isAndroid, !iconRequests.contains(app.id) else { return }
        let token = generation
        iconRequests.insert(app.id)
        let data = try? await fetchIcon(device, app)
        guard token == generation else { return }
        guard !Task.isCancelled else { iconRequests.remove(app.id); return }
        if let data, let image = NSImage(data: data) { icons[app.id] = image }
    }

    func refreshMounts() async {
        guard !isBusy, let volumes else { return }
        let token = generation
        guard let mounts = try? await volumes.mounts(), token == generation, !isBusy, !Task.isCancelled else { return }
        self.mounts = mounts
    }

    func open() async {
        guard !isBusy, canOpen, let app = selectedApp, let volumes else { return }
        let token = generation
        isBusy = true; error = nil
        defer { if token == generation { isBusy = false } }
        do {
            // The worker reuses a live mount and remounts a volume already ejected in Finder.
            let volume = try await volumes.mount(app)
            guard token == generation, !Task.isCancelled else { return }
            mounts.removeAll { $0.bundleID == app.bundleIdentifier }
            mounts.append(volume)
            if !openFinder(volume.url) { error = "卷已挂载，但 Finder 未能打开：\(volume.path)" }
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = "无法挂载沙箱。请解锁设备，并确认此应用允许访问数据容器。\n\(error)"
        }
    }

    func eject() async {
        guard !isBusy, let volume = selectedMount, let volumes else { return }
        let token = generation
        isBusy = true; error = nil
        defer { if token == generation { isBusy = false } }
        do {
            try await volumes.unmount(volume)
            guard token == generation, !Task.isCancelled else { return }
            mounts.removeAll { $0.id == volume.id }
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = "无法弹出卷，请先关闭正在使用的文件。\n\(error)"
        }
    }
}

/// Selects an app; the actual file browser is Finder's native read-only WebDAV volume.
public struct DeviceFilesPanel: View {
    private let device: DeviceSummary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DeviceFilesModel()
    @State private var search = ""

    public init(device: DeviceSummary) { self.device = device }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 28)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("在 Finder 中浏览").font(.headline)
                        Text(device.name).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await model.load(device) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("刷新应用").disabled(model.isBusy)
                }
                TextField(device.isAndroid ? "搜索应用包名" : "搜索应用名称或 Bundle ID", text: $search).textFieldStyle(.roundedBorder)
            }.padding(20)
            Divider()
            List(selection: $model.selection) {
                ForEach(model.apps.filter {
                    search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleIdentifier.localizedCaseInsensitiveContains(search)
                }) { app in
                    HStack(spacing: 12) {
                        Group {
                            if let icon = model.icons[app.id] {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else {
                                Image(systemName: "app.dashed").font(.title2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).lineLimit(1)
                            if app.name != app.bundleIdentifier {
                                Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if model.mounts.contains(where: { $0.bundleID == app.id }) {
                            Label("已挂载", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
                        } else if app.containerAccessible == true {
                            Text("可访问").font(.caption).foregroundStyle(.secondary)
                        } else if device.isAndroid && app.containerAccessible == false {
                            Text("不可访问").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5).tag(app.id).contentShape(Rectangle())
                    .task(id: app.id + "|" + (app.version ?? "")) { await model.loadIcon(app) }
                    .onTapGesture(count: 2) {
                        guard !model.isBusy else { return }
                        model.selection = app.id
                        Task { await model.open() }
                    }
                }
            }
            .disabled(model.isBusy)
            .overlay {
                if model.apps.isEmpty && model.isBusy { ProgressView("正在读取应用…") }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(5)
                }
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(device.isAndroid ? "支持允许 run-as 的可调试应用，可只读挂载并导出到 Mac。" : "只读挂载，可预览或拖到 Mac 导出。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    if model.selectedMount != nil {
                        Button("弹出", systemImage: "eject") { Task { await model.eject() } }.disabled(model.isBusy)
                    }
                    Spacer()
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("在 Finder 中打开") { Task { await model.open() } }
                        .keyboardShortcut(.defaultAction).disabled(!model.canOpen || model.isBusy)
                }
            }.padding(20)
        }
        .frame(width: 540, height: 540)
        .task {
            await model.load(device)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                await model.refreshMounts()
            }
        }
        .onDisappear { model.stop() }
    }
}
