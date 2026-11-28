import PhoneUseKit
import SwiftUI

struct PhysicalNetworkConditionPanel: View {
    let device: DeviceSummary
    @State private var state: DeviceNetworkCondition?
    @State private var selection: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("整机弱网").font(.headline)
            Text("所选档位会影响这台设备上所有 App 的网络。")
                .font(.callout).foregroundStyle(.secondary)
            if let state {
                if state.inUse {
                    let active = state.profiles.first { $0.id == state.activeProfile }
                    Text(active.map { "当前网络档位：\($0.name)" } ?? "设备正在使用其他模拟条件")
                    if !state.owned {
                        Text("请先在设备或启动该条件的工具中结束模拟。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if state.profiles.isEmpty {
                    Text("此设备未提供弱网档位。")
                } else {
                    Picker("网络档位", selection: $selection) {
                        Text("选择档位").tag(nil as String?)
                        ForEach(state.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                }
                if let profile = state.profiles.first(where: { $0.id == (state.inUse ? state.activeProfile : selection) }) {
                    Text(profile.detail).font(.caption).textSelection(.enabled)
                }
            }
            if let error { Text(error).font(.callout).textSelection(.enabled) }
            HStack {
                if state?.owned == true {
                    Button("恢复正常网络") { Task { await perform { try await device.setNetworkCondition(nil) } } }
                } else {
                    Button("启用整机弱网") {
                        guard let selection else { return }
                        Task { await perform { try await device.setNetworkCondition(selection) } }
                    }.disabled(state?.inUse != false || selection == nil)
                }
                Button("刷新") { Task { await refresh() } }
                if busy { ProgressView().controlSize(.small) }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(busy)
        .task { await refresh() }
    }

    @MainActor private func refresh() async {
        await perform { try await device.networkCondition() }
    }

    @MainActor private func perform(_ operation: () async throws -> DeviceNetworkCondition) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await operation()
            state = result
            if !result.profiles.contains(where: { $0.id == selection }) {
                selection = result.profiles.first { $0.id == "SlowNetwork3GAverage" }?.id
            }
            error = nil
        } catch {
            state = nil
            self.error = error.localizedDescription
        }
    }
}
