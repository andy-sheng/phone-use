import Foundation

/// Run with:
/// swiftc Sources/AutomationApp/AutomationSelection.swift Tests/AutomationSelectionTests.swift -o .build/test-selection
/// .build/test-selection
@main
struct AutomationSelectionTests {
    typealias Entry = AutomationSelection.TaskReference
    static let a1 = Entry(id: "a1", pluginID: "a")
    static let a2 = Entry(id: "a2", pluginID: "a")
    static let b1 = Entry(id: "b1", pluginID: "b")
    static let b2 = Entry(id: "b2", pluginID: "b")
    static let all = [a1, a2, b1, b2]
    static let plugins = ["a", "b", "empty", "empty2"]

    private static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw NSError(domain: "AutomationSelectionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        var selection = AutomationSelection()
        selection.reconcile(pluginIDs: plugins, tasks: all)
        try check(selection.pluginID == nil && selection.taskID == nil, "First launch waits for an explicit plugin load")
        try check(!selection.selectTask(b2, tasks: all), "Opening a task cannot implicitly load a plugin")
        try check(selection.loadPlugin("b", pluginIDs: plugins, tasks: all), "An available plugin can be loaded")
        try check(selection.pluginID == "b" && selection.taskID == nil, "Loading a plugin does not silently open its first task")
        try check(selection.selectTask(b2, tasks: all), "A task belonging to the loaded plugin opens")
        try check(!selection.selectTask(a1, tasks: all), "Opening another plugin's task is rejected")
        try check(selection.pluginID == "b" && selection.taskID == "b2", "Rejected cross-plugin open leaves the active plugin and task unchanged")
        try check(!selection.selectTask(Entry(id: "missing", pluginID: "b"), tasks: all), "Unknown task is rejected")

        selection.loadPlugin("a", pluginIDs: plugins, tasks: all)
        selection.selectTask(a2, tasks: all)
        selection.loadPlugin("b", pluginIDs: plugins, tasks: all)
        try check(selection.taskID == "b2", "Loading B again restores its remembered task")
        selection.loadPlugin("a", pluginIDs: plugins, tasks: all)
        try check(selection.taskID == "a2", "A has an independent remembered task")

        let serialized = try PropertyListEncoder().encode(selection.rememberedTasks)
        let persisted = try PropertyListDecoder().decode([String: String].self, from: serialized)
        var restored = AutomationSelection(pluginID: "a", legacyTaskID: "b1", rememberedTasks: persisted)
        restored.reconcile(pluginIDs: plugins, tasks: all)
        try check(restored.pluginID == "a" && restored.taskID == "a2", "Saved plugin selections are authoritative over old global keys")
        restored.unloadPlugin()
        restored.reconcile(pluginIDs: plugins, tasks: all)
        try check(restored.pluginID == nil && restored.taskID == nil, "Refreshing after unload does not reload a plugin")
        try check(restored.rememberedTasks == persisted, "Unloading preserves per-plugin task memory")
        var unloadedAfterRestart = AutomationSelection(pluginID: nil, legacyTaskID: "a2", rememberedTasks: restored.rememberedTasks)
        unloadedAfterRestart.reconcile(pluginIDs: plugins, tasks: all)
        try check(unloadedAfterRestart.pluginID == nil && unloadedAfterRestart.taskID == nil, "Explicit unloaded state survives restart despite stale legacy keys")
        unloadedAfterRestart.loadPlugin("a", pluginIDs: plugins, tasks: all)
        try check(unloadedAfterRestart.taskID == "a2", "Loading after a restart restores the plugin's own task")

        restored.loadPlugin("b", pluginIDs: plugins, tasks: all)
        restored.reconcile(pluginIDs: plugins, tasks: all.reversed())
        try check(restored.taskID == "b2", "Catalog order does not change current task")
        restored.removeTask(b2, remainingTasks: [a1, a2, b1], pluginIDs: plugins)
        try check(restored.pluginID == "b" && restored.taskID == nil && restored.rememberedTasks["b"] == nil,
                  "Deleting the current task leaves an empty current task, even if other tasks exist")
        restored.reconcile(pluginIDs: plugins, tasks: [a1, a2, b1])
        try check(restored.taskID == nil, "Catalog refresh does not fill an explicitly cleared task selection")
        restored.selectTask(b1, tasks: [a1, a2, b1])
        restored.removeTask(a2, remainingTasks: [a1, b1], pluginIDs: plugins)
        try check(restored.pluginID == "b" && restored.taskID == "b1", "Deleting an inactive plugin's task does not change current selection")
        restored.loadPlugin("a", pluginIDs: plugins, tasks: [a1, b1])
        try check(restored.taskID == nil, "A deleted remembered task is not replaced by another task")

        restored.loadPlugin("empty", pluginIDs: plugins, tasks: all)
        try check(restored.pluginID == "empty" && restored.taskID == nil, "Empty plugin never borrows another plugin's task")
        restored.loadPlugin("empty2", pluginIDs: plugins, tasks: all)
        try check(restored.pluginID == "empty2" && restored.taskID == nil, "Loading another empty plugin replaces the active plugin")
        try check(!restored.loadPlugin("unknown", pluginIDs: plugins, tasks: all), "Unavailable plugin load is rejected")
        try check(restored.pluginID == "empty2", "A rejected load preserves the active plugin")

        restored.loadPlugin("b", pluginIDs: plugins, tasks: all)
        restored.selectTask(b2, tasks: all)
        restored.reconcile(pluginIDs: ["a"], tasks: all)
        try check(restored.pluginID == nil && restored.taskID == nil && restored.rememberedTasks["b"] == "b2",
                  "A removed plugin unloads without choosing a replacement, while retaining its task memory")
        try check(!restored.loadPlugin("b", pluginIDs: ["a"], tasks: all), "Saved tasks alone cannot make a missing plugin loadable")
        restored.reconcile(pluginIDs: plugins, tasks: all)
        try check(restored.pluginID == nil, "Reinstalling a plugin does not automatically activate it")
        restored.loadPlugin("b", pluginIDs: plugins, tasks: all)
        try check(restored.taskID == "b2", "An explicitly loaded reinstalled plugin restores its task")
        restored.reconcile(pluginIDs: plugins, tasks: [a1, a2, b1])
        try check(restored.taskID == nil && restored.rememberedTasks["b"] == "b2", "A temporarily unavailable task is not silently replaced")
        restored.reconcile(pluginIDs: plugins, tasks: all)
        try check(restored.taskID == "b2", "An unavailable task can be restored when its descriptor returns")

        var legacy = AutomationSelection(pluginID: "a", legacyTaskID: "a2")
        legacy.reconcile(pluginIDs: plugins, tasks: all)
        try check(legacy.rememberedTasks["a"] == "a2" && legacy.taskID == "a2", "Legacy global selection migrates without changing task")
        var globalLegacy = AutomationSelection(legacyTaskID: "b2")
        globalLegacy.reconcile(pluginIDs: plugins, tasks: all)
        try check(globalLegacy.pluginID == "b" && globalLegacy.taskID == "b2", "Legacy global task restores its installed owning plugin")
        var unattributed = AutomationSelection(pluginID: "unassigned", legacyTaskID: "old")
        unattributed.reconcile(pluginIDs: plugins, tasks: [Entry(id: "old", pluginID: "unassigned")])
        try check(unattributed.pluginID == nil, "An unattributed legacy document cannot activate a missing plugin")
        unattributed.reconcile(pluginIDs: plugins, tasks: [Entry(id: "old", pluginID: "a"), a1])
        try check(unattributed.pluginID == "a" && unattributed.taskID == "old" && unattributed.rememberedTasks["unassigned"] == nil,
                  "Legacy document migration preserves its task UUID and moves memory to its owning plugin")
        unattributed.removeTask(Entry(id: "old", pluginID: "a"), remainingTasks: [], pluginIDs: plugins)
        try check(unattributed.pluginID == "a" && unattributed.taskID == nil && unattributed.rememberedTasks["a"] == nil,
                  "Deleting the last task keeps the plugin loaded and removes obsolete memory")

        var cancelledLegacy = AutomationSelection(pluginID: "unassigned", legacyTaskID: "old")
        cancelledLegacy.unloadPlugin()
        cancelledLegacy.reconcile(pluginIDs: plugins, tasks: [Entry(id: "old", pluginID: "a")])
        try check(cancelledLegacy.pluginID == nil && cancelledLegacy.taskID == nil, "Explicit unload cancels pending legacy activation")
        print("Automation selection: \(assertions) assertions passed")
    }
}
