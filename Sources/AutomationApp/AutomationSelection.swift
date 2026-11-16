import Foundation

/// One loaded plugin, with an independent remembered task for each plugin.
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

    mutating func reconcile(pluginIDs: [String], tasks: [TaskReference]) {
        // A runtime migration may assign an old document to its owning plugin.
        // Move its remembered selection, without implicitly loading another plugin.
        for (owner, remembered) in rememberedTasks {
            if let task = tasks.first(where: { $0.id == remembered }), task.pluginID != owner {
                rememberedTasks[task.pluginID] = rememberedTasks[task.pluginID] ?? task.id
                rememberedTasks.removeValue(forKey: owner)
            }
        }
        if let legacyTaskID, let task = tasks.first(where: { $0.id == legacyTaskID }),
           pluginIDs.contains(task.pluginID) {
            // Only migrate a legacy global selection once. An explicit unload clears it.
            rememberedTasks[task.pluginID] = task.id
            pluginID = task.pluginID
            self.legacyTaskID = nil
        }
        if let pluginID, !pluginIDs.contains(pluginID) {
            self.pluginID = nil
        }
        restoreTask(from: tasks)
    }

    @discardableResult
    mutating func loadPlugin(_ id: String, pluginIDs: [String], tasks: [TaskReference]) -> Bool {
        guard pluginIDs.contains(id) else { return false }
        legacyTaskID = nil
        pluginID = id
        restoreTask(from: tasks)
        return true
    }

    mutating func unloadPlugin() {
        legacyTaskID = nil
        pluginID = nil
        taskID = nil
    }

    @discardableResult
    mutating func selectTask(_ task: TaskReference, tasks: [TaskReference]) -> Bool {
        guard task.pluginID == pluginID, tasks.contains(task) else { return false }
        legacyTaskID = nil
        taskID = task.id
        rememberedTasks[task.pluginID] = task.id
        return true
    }

    mutating func removeTask(_ task: TaskReference, remainingTasks: [TaskReference], pluginIDs: [String]) {
        if rememberedTasks[task.pluginID] == task.id { rememberedTasks.removeValue(forKey: task.pluginID) }
        if legacyTaskID == task.id { legacyTaskID = nil }
        if taskID == task.id && pluginID == task.pluginID { taskID = nil }
        reconcile(pluginIDs: pluginIDs, tasks: remainingTasks)
    }

    private mutating func restoreTask(from tasks: [TaskReference]) {
        guard let pluginID else { taskID = nil; return }
        let scoped = tasks.filter { $0.pluginID == pluginID }
        if let remembered = rememberedTasks[pluginID], scoped.contains(where: { $0.id == remembered }) {
            taskID = remembered
        } else {
            taskID = nil
            // Preserve unavailable selections, including a removed plugin's built-in task.
            // They can be restored if that plugin is installed again.
        }
    }
}
