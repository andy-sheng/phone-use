import AppKit
import DeviceHubKit
import SwiftUI

/// The task pane is a view of the app-owned run. Hiding it never stops a task.
struct AutomationPanel: View {
    let device: DeviceSummary?
    @ObservedObject var automation: AutomationModel
    let importTask: () -> Void
    let openLibrary: () -> Void
    let managePlugins: () -> Void
    let close: () -> Void
    @AppStorage("automation.console.visible") private var showsConsole = true
    @AppStorage("automation.console.autoscroll") private var autoScroll = true

    private var task: AutomationTask? { automation.displayedTask }
    private var canConnect: Bool { device?.isReady == true && automation.isPrepared && !automation.isImporting && !automation.isRefreshingTasks && !automation.isInstalling }
    private var canStart: Bool { canConnect && task.map({ automation.canRun($0) }) == true }

    private var statusTitle: String {
        if automation.isStopping { return "正在停止" }
        if automation.isRunning { return automation.isProbe ? "正在检查连接" : "正在运行" }
        switch automation.outcome {
        case "probe_complete": return "连接正常"
        case "cancelled": return "任务已停止"
        case "failed": return "执行失败"
        case "completed": return "流程已完成"
        default: return task.map({ automation.canRun($0) }) == false ? "待适配" : device?.isReady == true ? "待开始" : "等待设备"
        }
    }

    private var statusColor: Color {
        if automation.isRunning { return .accentColor }
        switch automation.outcome {
        case "failed": return .red
        case "probe_complete", "completed": return .green
        case "cancelled": return .orange
        default: return .secondary
        }
    }

    private var statusMessage: String {
        guard !automation.isRunning else { return automation.message }
        if !automation.isPrepared { return "自动化运行环境尚未准备。" }
        if automation.outcome != nil { return automation.message }
        if task.map({ automation.canRun($0) }) == false { return "任务已保存。请先处理下方的兼容信息。" }
        guard let device else { return "请先选择并连接一台 iPhone 或 Android 设备。" }
        return device.isReady ? "请确认设备画面符合任务说明，再开始运行。" : "请先完成所选设备的连接准备。"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("自动化").font(.headline)
                Spacer()
                Button(action: openLibrary) {
                    Label("任务库", systemImage: "list.bullet.rectangle")
                }
                Button(action: importTask) {
                    Label("导入", systemImage: "plus")
                }
                .disabled(!automation.canImport)
                Button(action: managePlugins) { Image(systemName: "puzzlepiece.extension") }.help("管理插件")
                Button(action: close) {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("收起任务面板")
                .accessibilityLabel("收起任务面板")
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            Divider()
            if !automation.pluginIDs.isEmpty {
                Picker("插件", selection: $automation.selectedPluginID) {
                    ForEach(automation.pluginIDs, id: \.self) { id in
                        Text(automation.pluginName(id)).tag(Optional(id))
                    }
                }
                .disabled(automation.isBusy)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
            }
            if showsConsole {
                VSplitView {
                    taskWorkspace
                        .frame(minHeight: 250, idealHeight: 500, maxHeight: .infinity)
                    AutomationConsole(automation: automation, autoScroll: $autoScroll) {
                        showsConsole = false
                    }
                    .frame(minHeight: 120, idealHeight: 240, maxHeight: .infinity)
                }
            } else {
                taskWorkspace
                Divider()
                AutomationConsoleHeader(count: automation.logs.count, expanded: false) { showsConsole = true }
            }
            Divider()
            taskActions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var taskWorkspace: some View {
        VStack(spacing: 0) {
            if let task {
                ScrollView {
                    taskDetails(task).padding(18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(automation.plugins.isEmpty ? "还没有可用插件" : "还没有打开的任务", systemImage: "puzzlepiece.extension")
                } description: {
                    Text(automation.plugins.isEmpty ? "安装插件，为设备添加自动化任务。" : "从任务库选择内置任务，或导入当前插件支持的任务。")
                } actions: {
                    HStack {
                        if automation.canImport { Button("导入任务", action: importTask).buttonStyle(.borderedProminent) }
                        Button(automation.plugins.isEmpty ? "安装插件" : "管理插件", action: managePlugins)
                        if !automation.tasks.isEmpty { Button("任务库", action: openLibrary) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskDetails(_ task: AutomationTask) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            taskIdentity(task)
            Text(task.metadata.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if let notes = task.metadata.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label("运行说明", systemImage: "info.circle").font(.callout.weight(.medium))
                    ForEach(notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            if !task.parameters.isEmpty { taskOptions(task) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    if automation.isRunning { ProgressView().controlSize(.mini) }
                    else { Circle().fill(statusColor).frame(width: 6, height: 6) }
                    Text(statusTitle).font(.callout.weight(.medium))
                }
                Text(statusMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            if automation.canRun(task) {
                executionSteps
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("需要适配", systemImage: "wrench.and.screwdriver").font(.callout.weight(.medium))
                    ForEach(Array(automation.issues(for: task).enumerated()), id: \.offset) { _, issue in
                        Text(issue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func taskIdentity(_ task: AutomationTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: task.isBuiltIn ? "puzzlepiece.extension" : "doc.text")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.black.opacity(0.75))
                    .frame(width: 34, height: 34)
                    .background(task.isBuiltIn ? .orange : .cyan, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.title3.weight(.semibold))
                    Text(task.metadata.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !task.isBuiltIn {
                HStack {
                    Text(task.metadata.source + (task.metadata.author.isEmpty ? "" : " · \(task.metadata.author)"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    if let file = task.file {
                        Button("查看任务") { NSWorkspace.shared.open(file) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            if automation.isRunning, let target = automation.runDevice {
                Label("运行于 \(target.name)", systemImage: target.deviceIcon)
                    .font(.caption).foregroundStyle(.secondary)
                if device?.id != target.id {
                    Text("预览已切换，任务仍在原设备运行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func taskOptions(_ task: AutomationTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("任务选项", systemImage: "slider.horizontal.3").font(.callout.weight(.medium))
            ForEach(task.parameters) { parameter in
                VStack(alignment: .leading, spacing: 4) {
                    parameterControl(parameter, task: task)
                    if let description = parameter.description, !description.isEmpty {
                        Text(description).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(automation.isRunning)
    }

    @ViewBuilder
    private func parameterControl(_ parameter: AutomationParameter, task: AutomationTask) -> some View {
        switch parameter.type {
        case "integer":
            let value = Binding<Int>(get: { automation.value(for: parameter, task: task).integer },
                                     set: { automation.setValue(.integer($0), for: parameter, task: task) })
            Stepper(value: value, in: (parameter.min ?? 0)...Swift.max(parameter.min ?? 0, parameter.max ?? 9999)) {
                Text("\(parameter.title)：\(value.wrappedValue)").font(.caption)
            }
        case "boolean":
            Toggle(parameter.title, isOn: Binding(get: { automation.value(for: parameter, task: task).boolean },
                                                  set: { automation.setValue(.boolean($0), for: parameter, task: task) }))
                .font(.caption)
        case "choice":
            Picker(parameter.title, selection: Binding(get: { automation.value(for: parameter, task: task).string },
                                                       set: { automation.setValue(.string($0), for: parameter, task: task) })) {
                ForEach(parameter.choices ?? []) { choice in Text(choice.title).tag(choice.value) }
            }.font(.caption)
        case "string":
            TextField(parameter.title, text: Binding(get: { automation.value(for: parameter, task: task).string },
                                                    set: { automation.setValue(.string($0), for: parameter, task: task) }))
                .textFieldStyle(.roundedBorder)
        default:
            Text("暂不支持此选项：\(parameter.title)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var executionSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("执行步骤").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(automation.phases.enumerated()), id: \.element) { index, phase in
                let completed = automation.completedPhases.contains(phase.id)
                    || (phase.id == "connecting" && device?.isReady == true && automation.phase != "connecting")
                let active = automation.isRunning && (!automation.isProbe || phase.id == "connecting")
                    && automation.phase == phase.id && !completed
                let interrupted = !automation.isRunning && automation.phase == phase.id && !completed
                    && ["failed", "cancelled"].contains(automation.outcome ?? "")
                let stateText = completed ? (phase.id == "connecting" ? "已就绪" : "已完成")
                    : active ? "进行中" : interrupted ? (automation.outcome == "cancelled" ? "已停止" : "未完成") : "待执行"
                HStack(spacing: 9) {
                    ZStack {
                        Circle().fill(completed ? Color.green.opacity(0.12) : active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                        if completed {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.green)
                        } else {
                            Text("\(index + 1)").font(.caption2).foregroundStyle(active ? Color.accentColor : .secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(phase.title).font(.callout)
                        .foregroundStyle(completed ? Color.primary : active ? Color.accentColor : .secondary)
                    Spacer(minLength: 4)
                    Text(stateText)
                        .font(.caption2)
                        .foregroundStyle(completed ? Color.green : active ? Color.accentColor : .secondary)
                }
            }
        }
    }

    private var taskActions: some View {
        HStack(spacing: 9) {
            Button {
                if let device { automation.start(device: device, probe: true) }
            } label: {
                Text("检查连接").frame(maxWidth: .infinity)
            }
            .disabled(!canConnect || automation.isRunning)
            if automation.isRunning {
                Button(role: .destructive) {
                    automation.stop()
                } label: {
                    Label(automation.isStopping ? "正在停止" : "停止任务", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(automation.isStopping)
            } else {
                Button {
                    if let device { automation.start(device: device) }
                } label: {
                    Label("开始任务", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
        }
        .controlSize(.large)
        .padding(16)
    }

}
