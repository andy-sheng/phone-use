import PhoneUseKit
import SwiftUI

struct SimulatorCreationSheet: View {
    enum Family: String, CaseIterable, Identifiable {
        case iPhone, iPad
        var id: Self { self }
        var icon: String { self == .iPad ? "ipad" : "iphone" }
    }

    let family: Family
    let created: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var runtimes: [SimulatorLifecycle.Runtime] = []
    @State private var runtimeID = ""
    @State private var modelID = ""
    @State private var name = ""
    @State private var loading = true
    @State private var creating = false
    @State private var error: String?

    private var models: [SimulatorLifecycle.Runtime.Model] {
        runtimes.first { $0.id == runtimeID }?.supportedDeviceTypes.filter { $0.productFamily == family.rawValue } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("创建 \(family.rawValue) 模拟器").font(.headline)
            if loading {
                ProgressView("正在读取模拟器机型和系统版本…")
            } else if runtimes.isEmpty {
                Text("没有可用于 \(family.rawValue) 的模拟器运行时。").foregroundStyle(.secondary)
                Link("在 Xcode 中添加平台…", destination: URL(string: "xcode://settings/components/addSimulator")!)
            } else {
                Form {
                    TextField("名称", text: $name, prompt: Text(models.first { $0.id == modelID }?.name ?? ""))
                    Picker("系统版本", selection: $runtimeID) {
                        ForEach(runtimes) { Text($0.name).tag($0.id) }
                    }
                    Picker("机型", selection: $modelID) {
                        ForEach(models) { Text($0.name).tag($0.id) }
                    }
                }
                .disabled(creating)
                .onChange(of: runtimeID) { _, _ in
                    if !models.contains(where: { $0.id == modelID }) { modelID = models.first?.id ?? "" }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if !loading && runtimes.isEmpty {
                    Button("重新加载") { Task { await load() } }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Button(creating ? "正在创建…" : "创建") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || creating || !models.contains { $0.id == modelID })
            }
        }
        .padding(22)
        .frame(width: 420)
        .interactiveDismissDisabled(creating)
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            runtimes = try await SimulatorLifecycle.creationOptions().filter { runtime in
                runtime.supportedDeviceTypes.contains { $0.productFamily == family.rawValue }
            }
            runtimeID = runtimes.first?.id ?? ""
            modelID = models.first?.id ?? ""
        } catch {
            self.error = String(describing: error)
        }
    }

    private func create() {
        guard !creating else { return }
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let id = try await SimulatorLifecycle.create(name: name, deviceType: modelID, runtime: runtimeID)
                created(id)
                dismiss()
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}
