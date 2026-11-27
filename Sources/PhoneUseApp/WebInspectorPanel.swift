import Foundation
import PhoneUseKit
import SwiftUI

private struct InspectablePage: Decodable, Identifiable {
    let page_id, title, url, bundle_id, kind: String
    let attached, attached_here: Bool
    var id: String { page_id }
}

struct WebInspectorPanel: View {
    let device: DeviceSummary?
    let detached: Bool
    let toggleWindow: () -> Void
    @State private var pages: [InspectablePage] = []
    @State private var page: InspectablePage?
    @AppStorage("phoneuse.chromeInspector") private var chrome = true
    @State private var revision = 0
    @State private var busy = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "safari").foregroundStyle(.secondary)
                Text(page.map { $0.title.isEmpty ? $0.bundle_id : $0.title } ?? "可调试页面")
                    .font(.headline).lineLimit(1)
                Spacer()
                if page == nil {
                    Picker("调试器", selection: $chrome) {
                        Text("Chrome DevTools").tag(true)
                        Text("WebKit").tag(false)
                    }
                    .labelsHidden().fixedSize()
                } else {
                    Text(chrome ? "Chrome DevTools" : "WebKit").font(.caption).foregroundStyle(.secondary)
                }
                if busy { ProgressView().controlSize(.small) }
                if page != nil {
                    Button("断开") { select(nil) }
                } else if device != nil {
                    Button { revision += 1 } label: { Label("刷新页面", systemImage: "arrow.clockwise") }
                        .labelStyle(.iconOnly).disabled(busy)
                }
                let position = detached ? "停靠到主窗口下方" : "在独立窗口中打开"
                Button(action: toggleWindow) {
                    Label(position, systemImage: detached ? "rectangle.bottomthird.inset.filled" : "macwindow.on.rectangle")
                }
                .labelStyle(.iconOnly)
                .help(position)
            }
            .padding(10)
            Divider()
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(10)
            }
            if device == nil {
                ContentUnavailableView("请选择已就绪的 iPhone 或 iPad", systemImage: "safari")
            } else if page == nil {
                if pages.isEmpty && !busy && error == nil {
                    ContentUnavailableView("没有可调试页面", systemImage: "safari",
                        description: Text("在设备的 Safari 高级设置中开启网页检查器，然后打开网页并刷新。"))
                } else {
                    List(pages) { item in
                        Button { select(item) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title.isEmpty ? item.bundle_id : item.title).lineLimit(1)
                                Text(item.url.isEmpty ? "\(item.bundle_id) · \(item.kind)" : item.url).lineLimit(2)
                                    .font(.caption).foregroundStyle(.secondary)
                                if item.attached && !item.attached_here { Text("其他调试器已连接").font(.caption) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled((item.attached && !item.attached_here) || (chrome && !["page", "javascript"].contains(item.kind)))
                    }.listStyle(.plain)
                }
            } else if let device, let page, error == nil {
                WebInspectorFrontend(device: device, pageID: page.id, chrome: chrome) { message in
                    guard self.page?.id == page.id else { return }
                    busy = false
                    error = message
                }
                .id(page.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: revision) {
            guard let device else { busy = false; return }
            guard page == nil else { return }
            busy = true
            error = nil
            do {
                struct Listing: Decodable { let pages: [InspectablePage] }
                let data = try await DeviceHub.shared.daemon().webInspector(device.udid, .list)
                let listing = try JSONDecoder().decode(Listing.self, from: data)
                try Task.checkCancellation()
                pages = listing.pages
            } catch {
                guard !Task.isCancelled else { return }
                self.error = String(describing: error)
            }
            busy = false
        }
    }

    private func select(_ choice: InspectablePage?) {
        page = choice
        error = nil
        busy = true
        revision += 1
    }
}
