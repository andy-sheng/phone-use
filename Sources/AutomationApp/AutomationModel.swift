import AppKit
import Darwin
import PhoneUseKit
import Foundation

@MainActor
final class AutomationModel: ObservableObject {
    struct LogEntry: Identifiable {
        enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR", success = "OK" }
        let id = UUID()
        let date: Date
        let message: String
        let level: Level
    }

    struct Runtime {
        let python: URL
        let directory: URL
        let bridge: URL
        let assets: URL
    }

    private struct Catalog: Decodable {
        let plugins: [AutomationPlugin]
        let errors: [String]?
    }

    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var message = "选择插件和任务后开始。"
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var outputDirectory: URL?
    @Published private(set) var screenshot: URL?
    @Published private(set) var outcome: String?
    @Published private(set) var runDevice: DeviceSummary?
    @Published private(set) var isProbe = false
    @Published private(set) var phase: String?
    @Published private(set) var completedPhases: Set<String> = []
    @Published private(set) var tasks: [AutomationTask] = []
    @Published private(set) var plugins: [AutomationPlugin] = []
    @Published private(set) var selectedPluginID: String?
    @Published private(set) var selectedTaskID: String?
    private var selection = AutomationSelection()
    private static let selectionsKey = "automation.selectedTasksByPlugin"
    @Published private(set) var isImporting = false
    @Published private(set) var importMessage: String?
    @Published private(set) var importGeneration = 0
    @Published private(set) var openGeneration = 0
    @Published private(set) var libraryError: String?
    @Published private(set) var taskLibraryError: String?
    @Published private(set) var pluginMessage: String?
    @Published private(set) var pluginInstallError: String?
    @Published private(set) var installGeneration = 0
    @Published private(set) var isInstalling = false
    @Published private(set) var runTask: AutomationTask?
    @Published private(set) var isRefreshingTasks = false
    @Published private var settingsRevision = 0

    var selectedPlugin: AutomationPlugin? { plugins.first { $0.id == selectedPluginID } }
    var selectedTask: AutomationTask? { tasks.first { $0.id == selectedTaskID && $0.pluginID == selectedPluginID } }
    var selectedPluginTitle: String { selectedPluginID.map(pluginName) ?? "自动化" }
    var displayedTask: AutomationTask? { isRunning ? (runTask ?? selectedTask) : selectedTask }
    var visibleTasks: [AutomationTask] { tasks.filter { $0.pluginID == selectedPluginID } }
    var pluginIDs: [String] { plugins.map(\.id).sorted() }
    var isBusy: Bool { isRunning || isImporting || isRefreshingTasks || isInstalling }
    var canImport: Bool { !(selectedPlugin?.imports.isEmpty ?? true) && !isBusy }
    var phases: [AutomationPhase] {
        if isProbe && (isRunning || outcome == "probe_complete") { return [.connecting] }
        return displayedTask?.phases ?? []
    }

    init() {
        tasks = Self.readLibrary()
        let defaults = UserDefaults.standard
        selection = AutomationSelection(pluginID: defaults.string(forKey: "automation.selectedPlugin"),
                                        legacyTaskID: defaults.string(forKey: "automation.selectedTask"),
                                        rememberedTasks: defaults.dictionary(forKey: Self.selectionsKey) as? [String: String])
        selectedPluginID = selection.pluginID
        selectedTaskID = selection.taskID
        isRefreshingTasks = true
        Task { await refreshLibrary() }
    }

    func pluginName(_ id: String) -> String {
        plugins.first(where: { $0.id == id })?.name ?? (id == "unassigned" ? "待迁移任务" : id + "（未安装）")
    }

    @discardableResult
    func loadPlugin(_ id: String) -> Bool {
        guard !isBusy, selection.loadPlugin(id, pluginIDs: pluginIDs, tasks: taskReferences) else { return false }
        applySelection()
        // Lock synchronously: no task can start or switch plugins while its documents refresh.
        isRefreshingTasks = true
        Task { await refreshLibrary() }
        openGeneration += 1
        return true
    }

    @discardableResult
    func unloadPlugin() -> Bool {
        guard !isBusy, selectedPluginID != nil else { return false }
        selection.unloadPlugin()
        applySelection()
        openGeneration += 1
        return true
    }

    private func reference(_ task: AutomationTask) -> AutomationSelection.TaskReference {
        AutomationSelection.TaskReference(id: task.id, pluginID: task.pluginID)
    }

    private var taskReferences: [AutomationSelection.TaskReference] { tasks.map(reference) }

    private func reconcileSelection() {
        selection.reconcile(pluginIDs: pluginIDs, tasks: taskReferences)
        applySelection()
    }

    private func applySelection() {
        let changed = selectedPluginID != selection.pluginID || selectedTaskID != selection.taskID
        selectedPluginID = selection.pluginID
        selectedTaskID = selection.taskID
        let defaults = UserDefaults.standard
        defaults.set(selection.rememberedTasks, forKey: Self.selectionsKey)
        defaults.set(selectedPluginID, forKey: "automation.selectedPlugin")
        defaults.set(selectedTaskID, forKey: "automation.selectedTask")
        guard changed else { return }
        taskLibraryError = nil
        outcome = nil
        phase = nil
        completedPhases = []
        logs = []
        screenshot = nil
        outputDirectory = nil
        runTask = nil
        runDevice = nil
        isProbe = false
        message = selectedPluginID == nil ? "选择一个插件加载。" :
            selectedTaskID == nil ? "从任务库选择或导入任务。" : "任务已就绪，点击开始。"
    }

    func canRun(_ task: AutomationTask) -> Bool {
        task.canRun && task.pluginID == selectedPlugin?.id && configurationIssues(for: task).isEmpty
    }

    func issues(for task: AutomationTask) -> [String] {
        var issues = task.metadata.issues + configurationIssues(for: task)
        if !plugins.contains(where: { $0.id == task.pluginID }) {
            issues.append("所需插件尚未安装或未能加载。任务内容会保留，安装兼容插件后可重新检查。")
        }
        return Array(Set(issues)).sorted()
    }

    func reloadPlugins() {
        guard !isBusy else { return }
        isRefreshingTasks = true
        Task { await refreshLibrary() }
    }

    private static func readLibrary() -> [AutomationTask] {
        let files = (try? FileManager.default.contentsOfDirectory(at: AutomationTask.libraryDirectory,
                                                                includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? AutomationTask.read($0) }
    }

    private func refreshLibrary() async {
        defer { isRefreshingTasks = false }
        guard !isRunning else { return }
        guard let runtime = Self.locateRuntime() else {
            libraryError = "自动化运行环境尚未准备。设备预览和手动操作仍可使用。"
            return
        }
        isRefreshingTasks = true
        do {
            let catalog = try JSONDecoder().decode(Catalog.self, from: await Self.request(["catalog"], runtime: runtime))
            var errors = catalog.errors ?? []
            plugins = catalog.plugins
            // Catalog discovery reads manifests only. Python task inspection belongs solely
            // to the loaded plugin; no plugin code is invoked while the host is unloaded.
            tasks = plugins.flatMap { plugin in plugin.tasks.map { AutomationTask.builtIn($0, plugin: plugin) } } + Self.readLibrary()
            reconcileSelection()
            if let plugin = selectedPlugin {
                do {
                    let refresh = try await Self.request(["refresh-library", "--plugin", plugin.id,
                                                          "--library", AutomationTask.libraryDirectory.path], runtime: runtime)
                    if let response = try JSONSerialization.jsonObject(with: refresh) as? [String: Any] {
                        errors += response["errors"] as? [String] ?? []
                    }
                } catch { errors.append(error.localizedDescription) }
                tasks = plugins.flatMap { plugin in plugin.tasks.map { AutomationTask.builtIn($0, plugin: plugin) } } + Self.readLibrary()
                reconcileSelection()
            }
            libraryError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func preparePluginInstall() {
        guard !isInstalling else { return }
        pluginMessage = nil
        pluginInstallError = nil
    }

    func installPlugin(_ package: URL) {
        installPlugin(arguments: ["--package", package.path], remote: false)
    }

    func installPlugin(fromURL text: String) {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy else { return }
        guard let url = URLComponents(string: address),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            pluginMessage = nil
            pluginInstallError = "请输入有效的 HTTP 或 HTTPS 插件包链接。"
            return
        }
        installPlugin(arguments: ["--url", address], remote: true)
    }

    private func installPlugin(arguments: [String], remote: Bool) {
        guard !isBusy else { return }
        preparePluginInstall()
        guard let runtime = Self.locateRuntime() else {
            pluginInstallError = "自动化运行环境尚未准备。"
            return
        }
        isInstalling = true
        pluginMessage = remote ? "正在下载、检查并安装插件…" : "正在检查并安装插件…"
        Task {
            defer { isInstalling = false }
            do {
                let result = try await Self.request(["install"] + arguments, runtime: runtime,
                                                    timeout: remote ? 180 : 60)
                let response = try JSONSerialization.jsonObject(with: result) as? [String: Any]
                // Installing a release must not activate its Python code, including updates
                // to the currently loaded plugin. Its task/config memory is retained.
                if let installedID = response?["plugin_id"] as? String, installedID == selectedPluginID {
                    selection.unloadPlugin()
                    applySelection()
                    openGeneration += 1
                }
                pluginMessage = (response?["message"] as? String ?? "插件已安装。") + " 请选中插件后加载。"
                await refreshLibrary()
                installGeneration += 1
            } catch {
                pluginMessage = nil
                pluginInstallError = error.localizedDescription
            }
        }
    }

    func openPluginsDirectory() {
        let directory = AutomationTask.supportDirectory.appendingPathComponent("Plugins", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { pluginMessage = error.localizedDescription }
    }

    func prepareImport() { importMessage = nil }

    @discardableResult
    func openTask(_ task: AutomationTask) -> Bool {
        guard !isBusy, task.pluginID == selectedPlugin?.id,
              tasks.contains(where: { reference($0) == reference(task) }) else { return false }
        guard selection.selectTask(reference(task), tasks: taskReferences) else { return false }
        applySelection()
        openGeneration += 1
        return true
    }

    func removeTask(_ task: AutomationTask) {
        guard !isBusy, task.pluginID == selectedPlugin?.id, let file = task.file,
              let index = tasks.firstIndex(where: { reference($0) == reference(task) }) else { return }
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            tasks.remove(at: index)
            UserDefaults.standard.removeObject(forKey: settingsKey(for: task))
            selection.removeTask(reference(task), remainingTasks: taskReferences, pluginIDs: pluginIDs)
            applySelection()
            taskLibraryError = nil
        } catch { taskLibraryError = "无法删除任务：\(error.localizedDescription)" }
    }

    func importTask(source: String? = nil, file: URL? = nil) {
        guard canImport, let plugin = selectedPlugin else { return }
        guard let runtime = Self.locateRuntime() else {
            importMessage = "自动化运行环境尚未准备。"
            return
        }
        isImporting = true
        importMessage = "正在读取并检查任务…"
        let output = AutomationTask.libraryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        Task {
            do {
                var arguments = ["import", "--plugin", plugin.id, "--output", output.path]
                if let file { arguments += ["--file", file.path] }
                else { arguments += ["--source", source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""] }
                _ = try await Self.request(arguments, runtime: runtime)
                let imported = try AutomationTask.read(output)
                guard imported.pluginID == plugin.id else {
                    throw NSError(domain: "AutomationRuntime", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "导入的任务不属于当前插件。"])
                }
                tasks.append(imported)
                selection.selectTask(reference(imported), tasks: taskReferences)
                applySelection()
                importMessage = canRun(imported) ? "已导入，可在连接设备后运行。" : "任务已保存，运行前请查看兼容信息。"
                importGeneration += 1
            } catch {
                try? FileManager.default.removeItem(at: output)
                importMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    private func settingsKey(for task: AutomationTask) -> String { "automation.taskConfig.\(task.pluginID).\(task.id)" }

    private func configuration(for task: AutomationTask) -> [String: AutomationValue] {
        let data = UserDefaults.standard.data(forKey: settingsKey(for: task))
        let saved = data.flatMap { try? JSONDecoder().decode([String: AutomationValue].self, from: $0) } ?? [:]
        return task.parameters.reduce(into: [:]) { values, parameter in
            let legacy = parameter.legacyKey.flatMap { UserDefaults.standard.object(forKey: $0) }
            let legacyValue: AutomationValue?
            switch parameter.type {
            case "integer": legacyValue = (legacy as? Int).map(AutomationValue.integer)
            case "boolean": legacyValue = (legacy as? Bool).map(AutomationValue.boolean)
            default: legacyValue = (legacy as? String).map(AutomationValue.string)
            }
            values[parameter.key] = saved[parameter.key] ?? legacyValue ?? parameter.defaultValue ?? .null
        }
    }

    private func configurationIssues(for task: AutomationTask) -> [String] {
        let values = configuration(for: task)
        return task.parameters.compactMap { parameter in
            let value = values[parameter.key] ?? .null
            let valid: Bool
            switch (parameter.type, value) {
            case ("integer", .integer(let number)):
                valid = number >= (parameter.min ?? Int.min) && number <= (parameter.max ?? Int.max)
            case ("boolean", .boolean): valid = true
            case ("string", .string(let text)): valid = text.count <= 4000
            case ("choice", .string(let text)): valid = parameter.choices?.contains(where: { $0.value == text }) == true
            default: valid = false
            }
            return valid ? nil : "请更新任务选项「\(parameter.title)」，当前值不符合此插件版本。"
        }
    }

    func value(for parameter: AutomationParameter, task: AutomationTask) -> AutomationValue {
        _ = settingsRevision
        return configuration(for: task)[parameter.key] ?? .null
    }

    func setValue(_ value: AutomationValue, for parameter: AutomationParameter, task: AutomationTask) {
        guard !isBusy, task.id == selectedTaskID, task.pluginID == selectedPlugin?.id else { return }
        var values = configuration(for: task)
        values[parameter.key] = value
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: settingsKey(for: task))
            settingsRevision += 1
        }
    }

    private static func request(_ arguments: [String], runtime: Runtime, timeout: TimeInterval = 60) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = runtime.python
            process.arguments = ["-m", "devicehub_runtime"] + arguments
            process.environment = environment(runtime)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let started = Date()
            // Metadata inspection is plugin code too. A stalled importer must not leave
            // the library or its import sheet permanently locked.
            let deadline = DispatchWorkItem {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer { deadline.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let fallback = Date().timeIntervalSince(started) >= timeout ? "插件响应超时，已结束此次操作。" : "自动化运行环境调用失败。"
                throw NSError(domain: "AutomationRuntime", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: response?["error"] as? String ?? fallback])
            }
            return data
        }.value
    }

    nonisolated private static func environment(_ runtime: Runtime) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // automation-bridge must reach this app's daemon, not phone-use's.
        environment.merge(PhoneUseConfiguration.current.environment) { _, identity in identity }
        environment["PYTHONPATH"] = runtime.directory.path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }

    private var process: Process?
    private var stdout: Pipe?
    private var stdin: Pipe?
    private var diagnosticFile: FileHandle?
    private var pending = Data()
    private var runID = UUID()

    var isPrepared: Bool { Self.locateRuntime() != nil }

    func start(device: DeviceSummary, probe: Bool = false) {
        guard !isBusy, selectedPlugin != nil, device.isReady else { return }
        let task = selectedTask
        guard probe || task.map(canRun) == true else { return }
        guard let runtime = Self.locateRuntime() else {
            message = "自动化运行环境尚未准备。"
            return
        }
        let id = UUID()
        runID = id
        logs = []
        pending = Data()
        outcome = nil
        screenshot = nil
        isStopping = false
        runDevice = device
        isProbe = probe
        runTask = task
        phase = "connecting"
        completedPhases = []
        do {
            let directory = AutomationTask.supportDirectory.appendingPathComponent("Automation/\(id.uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            outputDirectory = directory
            let diagnosticURL = directory.appendingPathComponent("runtime.log")
            FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil)
            let diagnostic = try FileHandle(forWritingTo: diagnosticURL)
            diagnosticFile = diagnostic
            let child = Process()
            child.executableURL = runtime.python
            child.arguments = ["-m", "devicehub_runtime", probe ? "probe" : "run", "--device", device.udid,
                               "--bridge", runtime.bridge.path, "--assets", runtime.assets.path,
                               "--output", directory.path, "--watch-stdin"]
            if !probe, let task {
                child.arguments! += ["--plugin", task.pluginID]
                if let file = task.file { child.arguments! += ["--task-file", file.path] }
                else { child.arguments! += ["--task", task.metadata.taskID ?? task.metadata.entry] }
                let config = try JSONEncoder().encode(configuration(for: task))
                child.arguments! += ["--config", String(decoding: config, as: UTF8.self)]
            }
            child.environment = Self.environment(runtime)
            child.currentDirectoryURL = directory
            let input = Pipe()
            child.standardInput = input
            stdin = input
            child.standardError = diagnostic
            let pipe = Pipe()
            child.standardOutput = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in
                    guard let self, self.runID == id else { return }
                    self.receive(data)
                }
            }
            child.terminationHandler = { [weak self] child in
                let code = child.terminationStatus
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self, self.runID == id else { return }
                    self.finished(exitCode: code)
                }
            }
            process = child
            stdout = pipe
            message = probe ? "正在检查连接与识图能力…" : "正在启动\(task?.title ?? "任务")…"
            isRunning = true
            try child.run()
            appendLog(message, level: .info)
        } catch {
            stdout?.fileHandleForReading.readabilityHandler = nil
            process = nil
            stdout = nil
            try? stdin?.fileHandleForWriting.close()
            stdin = nil
            try? diagnosticFile?.close()
            diagnosticFile = nil
            isRunning = false
            outcome = "failed"
            message = "任务无法启动：\(error.localizedDescription)"
            appendLog(message, level: .error)
        }
    }

    func stop() {
        guard let process, process.isRunning, !isStopping else { return }
        isStopping = true
        message = "正在停止并释放触摸…"
        appendLog(message, level: .warning)
        process.interrupt()
        let id = runID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if let self, self.runID != id { return }
            guard process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    func clearVisibleLogs() { logs = [] }

    private func appendLog(_ text: String, level: LogEntry.Level, date: Date = Date()) {
        if logs.last?.message != text || logs.last?.level != level {
            logs.append(LogEntry(date: date, message: text, level: level))
        }
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
    }

    private func receive(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let text = object["message"] as? String else { continue }
            message = text
            let date = (object["time"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
            let status = object["status"] as? String
            let level: LogEntry.Level
            if object["event"] as? String == "error" || status == "failed" { level = .error }
            else if status == "cancelled" { level = .warning }
            else if object["event"] as? String == "result" { level = .success }
            else { level = .info }
            appendLog(text, level: level, date: date)
            if let current = object["phase"] as? String {
                phase = current
                if object["phase_status"] as? String == "completed" { completedPhases.insert(current) }
            }
            if object["event"] as? String == "result" {
                outcome = status
                if status == "probe_complete" { completedPhases.insert("connecting") }
                if status == "completed" { completedPhases.formUnion(phases.map(\.id)) }
                if let path = object["screenshot"] as? String { screenshot = URL(fileURLWithPath: path) }
            }
        }
    }

    private func finished(exitCode: Int32) {
        stdout?.fileHandleForReading.readabilityHandler = nil
        stdout = nil
        try? stdin?.fileHandleForWriting.close()
        stdin = nil
        process = nil
        try? diagnosticFile?.close()
        diagnosticFile = nil
        if outcome == nil {
            outcome = isStopping ? "cancelled" : "failed"
            message = isStopping ? "任务已停止" : "任务异常结束（\(exitCode)），可打开日志查看详情。"
            appendLog(message, level: isStopping ? .warning : .error)
        }
        isRunning = false
        isStopping = false
    }

    static func locateRuntime() -> Runtime? {
        let manager = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let candidate = Runtime(python: resources.appendingPathComponent("python/bin/python3"),
                                    directory: resources.appendingPathComponent("automation"),
                                    bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/automation-bridge"),
                                    assets: resources.appendingPathComponent("maa-assets"))
            if manager.isExecutableFile(atPath: candidate.python.path),
               manager.fileExists(atPath: candidate.directory.appendingPathComponent("devicehub_runtime").path) { return candidate }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidate = Runtime(python: root.appendingPathComponent(".venv-maa/bin/python"),
                                directory: root.appendingPathComponent("Automation"),
                                bridge: root.appendingPathComponent(".build/debug/automation-bridge"),
                                assets: root.appendingPathComponent(".build/maa-core"))
        guard manager.isExecutableFile(atPath: candidate.python.path),
              manager.fileExists(atPath: candidate.directory.appendingPathComponent("devicehub_runtime").path) else { return nil }
        return candidate
    }

    deinit {
        stdout?.fileHandleForReading.readabilityHandler = nil
        try? stdin?.fileHandleForWriting.close()
        if let process, process.isRunning { process.interrupt() }
    }
}
