import Foundation

/// Keeps task selection scoped to a plugin, independently of catalog loading and the UI.
struct AutomationSelection {
    struct TaskReference: Equatable {
        let id: String
        let pluginID: String
    }

    private(set) var pluginID: String?
    private(set) var taskID: String?
    private(set) var rememberedTasks: [String: String]
    private var legacyTaskID: String?

    init(pluginID: String? = nil, legacyTaskID: String? = nil, rememberedTasks: [String: String]? = nil) {
        self.pluginID = pluginID
        self.taskID = rememberedTasks == nil ? legacyTaskID : pluginID.flatMap { rememberedTasks?[$0] }
        self.rememberedTasks = rememberedTasks ?? [:]
        // An existing dictionary is authoritative. Old global keys are used only on migration.
        self.legacyTaskID = rememberedTasks == nil ? legacyTaskID : nil
        if rememberedTasks == nil, let pluginID, let legacyTaskID {
            self.rememberedTasks[pluginID] = legacyTaskID
        }
    }

    mutating func reconcile(pluginIDs: [String], tasks: [TaskReference], preferredPluginID: String? = nil) {
        if let legacyTaskID, let task = tasks.first(where: { $0.id == legacyTaskID }) {
            // Legacy documents receive their owning plugin during runtime migration.
            if let oldPlugin = pluginID, oldPlugin != task.pluginID, rememberedTasks[oldPlugin] == task.id {
                rememberedTasks.removeValue(forKey: oldPlugin)
            }
            rememberedTasks[task.pluginID] = task.id
            pluginID = task.pluginID
            taskID = task.id
            if task.pluginID != "unassigned" { self.legacyTaskID = nil }
        } else if let taskID, let currentPlugin = pluginID,
                  let task = tasks.first(where: { $0.id == taskID }), task.pluginID != currentPlugin {
            // Follow a selected document when a migration changes its plugin attribution.
            if rememberedTasks[currentPlugin] == task.id { rememberedTasks.removeValue(forKey: currentPlugin) }
            pluginID = task.pluginID
            rememberedTasks[task.pluginID] = task.id
        }
        if pluginID == nil || !pluginIDs.contains(pluginID!) {
            pluginID = preferredPluginID.flatMap { pluginIDs.contains($0) ? $0 : nil } ?? pluginIDs.first
        }
        restoreTask(from: tasks)
    }

    @discardableResult
    mutating func selectPlugin(_ id: String, pluginIDs: [String], tasks: [TaskReference]) -> Bool {
        guard pluginIDs.contains(id) else { return false }
        legacyTaskID = nil
        pluginID = id
        restoreTask(from: tasks)
        return true
    }

    @discardableResult
    mutating func selectTask(_ task: TaskReference, tasks: [TaskReference]) -> Bool {
        guard tasks.contains(task) else { return false }
        legacyTaskID = nil
        pluginID = task.pluginID
        taskID = task.id
        rememberedTasks[task.pluginID] = task.id
        return true
    }

    mutating func removeTask(_ task: TaskReference, remainingTasks: [TaskReference], pluginIDs: [String]) {
        if rememberedTasks[task.pluginID] == task.id { rememberedTasks.removeValue(forKey: task.pluginID) }
        if legacyTaskID == task.id { legacyTaskID = nil }
        if taskID == task.id { taskID = nil }
        reconcile(pluginIDs: pluginIDs, tasks: remainingTasks)
    }

    private mutating func restoreTask(from tasks: [TaskReference]) {
        guard let pluginID else { taskID = nil; return }
        let scoped = tasks.filter { $0.pluginID == pluginID }
        if let remembered = rememberedTasks[pluginID], scoped.contains(where: { $0.id == remembered }) {
            taskID = remembered
        } else {
            taskID = scoped.first?.id
            if let taskID { rememberedTasks[pluginID] = taskID }
            // Preserve unavailable selections, including a removed plugin's built-in task.
            // They can be restored if that plugin is installed again.
        }
    }
}
