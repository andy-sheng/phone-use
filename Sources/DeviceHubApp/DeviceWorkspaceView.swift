import AppKit
import SwiftUI

/// Keeps the navigation sidebar and the resizable device/task panes inside the window.
struct DeviceWorkspaceView<Sidebar: View, Detail: View, Panel: View>: View {
    let showsPanel: Bool
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail
    @ViewBuilder var panel: Panel

    private let previewMinimumWidth: CGFloat = 300
    private let panelMinimumWidth: CGFloat = 340
    // Both native split views need room for their platform-specific dividers.
    private let dividerWidth = NSSplitView().dividerThickness

    private var detailMinimumWidth: CGFloat {
        previewMinimumWidth + (showsPanel ? panelMinimumWidth + dividerWidth : 0)
    }

    var body: some View {
        GeometryReader { window in
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(
                        min: 220, ideal: 250,
                        max: max(220, window.size.width - detailMinimumWidth - dividerWidth)
                    )
            } detail: {
                GeometryReader { available in
                    HSplitView {
                        detail
                            .frame(minWidth: previewMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
                        if showsPanel {
                            panel
                                .frame(minWidth: panelMinimumWidth, idealWidth: 480,
                                       maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: available.size.width, height: available.size.height)
                }
                // The native split already applies the floating sidebar's inset to its first
                // pane. Measure the full width so that inset is not counted a second time.
                .ignoresSafeArea(.container, edges: .horizontal)
                .frame(minWidth: detailMinimumWidth)
            }
        }
        .frame(minWidth: 940, minHeight: 680)
    }
}
