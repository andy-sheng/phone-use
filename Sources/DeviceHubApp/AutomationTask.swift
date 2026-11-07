import Foundation

/// JSON values are preserved in task settings as declared by each plugin.
enum AutomationValue: Codable, Equatable {
    case string(String), integer(Int), number(Double), boolean(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .boolean(result) }
        else if let result = try? value.decode(Int.self) { self = .integer(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else { self = .string(try value.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let result): try value.encode(result)
        case .integer(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .boolean(let result): try value.encode(result)
        case .null: try value.encodeNil()
        }
    }

    var string: String { if case .string(let value) = self { return value }; return "" }
    var integer: Int { if case .integer(let value) = self { return value }; return 0 }
    var boolean: Bool { if case .boolean(let value) = self { return value }; return false }
}

struct AutomationParameter: Decodable, Identifiable {
    struct Choice: Decodable, Identifiable {
        let value: String
        let title: String
        var id: String { value }
    }
    let key: String
    let title: String
    let type: String
    let defaultValue: AutomationValue?
    let min: Int?
    let max: Int?
    let choices: [Choice]?
    let description: String?
    let legacyKey: String?
    var id: String { key }
    enum CodingKeys: String, CodingKey {
        case key, title, type, min, max, choices, description
        case defaultValue = "default", legacyKey = "legacy_key"
    }
}

struct AutomationPhase: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    static let connecting = AutomationPhase(id: "connecting", title: "连接设备")
}

struct AutomationPlugin: Decodable, Identifiable {
    struct ImportSource: Decodable, Identifiable {
        let id: String
        let title: String
        let kind: String
        let placeholder: String?
        let extensions: [String]?
        private let helpURLString: String?
        let helpTitle: String?
        var helpURL: URL? {
            guard let text = helpURLString, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url
        }
        enum CodingKeys: String, CodingKey {
            case id, title, kind, placeholder, extensions
            case helpURLString = "help_url", helpTitle = "help_title"
        }
    }
    let id: String
    let name: String
    let version: String
    let description: String
    let location: String?
    let imports: [ImportSource]
    let tasks: [AutomationTask.Metadata]
}

struct AutomationTask: Identifiable {
    struct Metadata: Decodable {
        var id: String?
        let title: String
        let subtitle: String
        let description: String
        let source: String
        let author: String
        let kind: String
        let entry: String
        var issues: [String]
        var notes: [String]?
        var pluginID: String?
        var pluginVersion: String?
        var taskID: String?
        var parameters: [AutomationParameter]?
        var phases: [AutomationPhase]?
        enum CodingKeys: String, CodingKey {
            case id, title, subtitle, description, source, author, kind, entry, issues, notes, parameters, phases
            case pluginID = "plugin_id", pluginVersion = "plugin_version", taskID = "task_id"
        }
    }

    let id: String
    let metadata: Metadata
    let file: URL?

    var title: String { metadata.title }
    var isBuiltIn: Bool { file == nil }
    var canRun: Bool { metadata.issues.isEmpty && metadata.pluginID != nil }
    var pluginID: String { metadata.pluginID ?? "unassigned" }
    var parameters: [AutomationParameter] { metadata.parameters ?? [] }
    var phases: [AutomationPhase] {
        let phases = metadata.phases ?? [AutomationPhase(id: "executing", title: "执行任务")]
        return phases.contains(where: { $0.id == "connecting" }) ? phases : [.connecting] + phases
    }

    static var libraryDirectory: URL {
        supportDirectory.appendingPathComponent("TaskLibrary", isDirectory: true)
    }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeviceHub", isDirectory: true)
    }

    static func read(_ file: URL) throws -> AutomationTask {
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: file))
        return AutomationTask(id: file.deletingPathExtension().lastPathComponent, metadata: metadata, file: file)
    }

    static func builtIn(_ metadata: Metadata, plugin: AutomationPlugin) -> AutomationTask {
        var descriptor = metadata
        descriptor.pluginID = plugin.id
        descriptor.pluginVersion = plugin.version
        descriptor.taskID = descriptor.taskID ?? descriptor.id
        return AutomationTask(id: "builtin.\(plugin.id).\(descriptor.taskID ?? descriptor.entry)", metadata: descriptor, file: nil)
    }
}
