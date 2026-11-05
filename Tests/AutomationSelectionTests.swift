import Foundation

/// Run with:
/// swiftc Sources/DeviceHubApp/AutomationSelection.swift Tests/AutomationSelectionTests.swift -o .build/test-selection
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
        selection.reconcile(pluginIDs: plugins, tasks: all, preferredPluginID: "b")
        try check(selection.pluginID == "b" && selection.taskID == "b1", "First launch honors the preferred plugin and chooses its first task")

        selection.selectTask(b2, tasks: all)
        selection.selectPlugin("a", pluginIDs: plugins, tasks: all)
        selection.selectTask(a2, tasks: all)
        selection.selectPlugin("b", pluginIDs: plugins, tasks: all)
        try check(selection.taskID == "b2", "Switching back restores plugin B's own selection")
        selection.selectPlugin("a", pluginIDs: plugins, tasks: all)
        try check(selection.taskID == "a2", "Plugin A's independent selection survives switching")

        let serialized = try PropertyListEncoder().encode(selection.rememberedTasks)
        let persisted = try PropertyListDecoder().decode([String: String].self, from: serialized)
        var restored = AutomationSelection(pluginID: "a", legacyTaskID: "b1", rememberedTasks: persisted)
        restored.reconcile(pluginIDs: plugins, tasks: all)
        try check(restored.pluginID == "a" && restored.taskID == "a2", "Persisted plugin dictionary is authoritative over stale global keys")
        restored.selectPlugin("b", pluginIDs: plugins, tasks: all)
        try check(restored.taskID == "b2", "All plugin selections survive persistence round trip")

        restored.reconcile(pluginIDs: plugins, tasks: all.reversed())
        try check(restored.taskID == "b2", "Catalog ordering changes do not change selected task")
        restored.removeTask(b2, remainingTasks: [a1, a2, b1], pluginIDs: plugins)
        try check(restored.pluginID == "b" && restored.taskID == "b1", "Deleting active task chooses a task in the same plugin")
        restored.removeTask(a2, remainingTasks: [a1, b1], pluginIDs: plugins)
        try check(restored.pluginID == "b" && restored.taskID == "b1", "Deleting another plugin's task does not change active selection")
        restored.selectPlugin("a", pluginIDs: plugins, tasks: [a1, b1])
        try check(restored.taskID == "a1", "Deleted remembered task falls back within its own plugin")

        restored.selectPlugin("empty", pluginIDs: plugins, tasks: all)
        try check(restored.pluginID == "empty" && restored.taskID == nil, "Empty plugin never borrows another plugin's task")
        restored.selectPlugin("empty2", pluginIDs: plugins, tasks: all)
        try check(restored.pluginID == "empty2" && restored.taskID == nil, "Two empty plugins remain distinct selections")
        try check(!restored.selectPlugin("unknown", pluginIDs: plugins, tasks: all), "Unknown plugin selection is rejected")
        try check(restored.pluginID == "empty2", "Rejected plugin selection leaves existing state unchanged")

        restored.selectTask(b2, tasks: all)
        try check(restored.pluginID == "b" && restored.taskID == "b2", "Opening a task explicitly selects its owning plugin")
        restored.reconcile(pluginIDs: ["a", "b"], tasks: all)
        try check(restored.taskID == "b2", "Missing installed plugin remains selectable when saved tasks still identify it")
        restored.reconcile(pluginIDs: ["a"], tasks: [a1, a2])
        try check(restored.pluginID == "a" && restored.rememberedTasks["b"] == "b2", "Unavailable plugin without tasks preserves its remembered task")
        restored.selectPlugin("b", pluginIDs: plugins, tasks: all)
        try check(restored.taskID == "b2", "Reinstalled plugin restores its original task")

        var legacy = AutomationSelection(pluginID: "a", legacyTaskID: "a2")
        legacy.reconcile(pluginIDs: plugins, tasks: all)
        try check(legacy.rememberedTasks["a"] == "a2" && legacy.taskID == "a2", "Legacy global selection migrates without changing task")
        var unattributed = AutomationSelection(pluginID: "unassigned", legacyTaskID: "old")
        unattributed.reconcile(pluginIDs: ["unassigned"], tasks: [Entry(id: "old", pluginID: "unassigned")])
        unattributed.reconcile(pluginIDs: ["a"], tasks: [Entry(id: "old", pluginID: "a"), a1])
        try check(unattributed.pluginID == "a" && unattributed.taskID == "old" && unattributed.rememberedTasks["unassigned"] == nil,
                  "Migrated document follows its new plugin while retaining its UUID")
        unattributed.removeTask(Entry(id: "old", pluginID: "a"), remainingTasks: [], pluginIDs: ["a"])
        try check(unattributed.pluginID == "a" && unattributed.taskID == nil && unattributed.rememberedTasks["a"] == nil,
                  "Deleting the last task keeps the plugin selected and removes obsolete memory")
        print("Automation selection: \(assertions) assertions passed")
    }
}
