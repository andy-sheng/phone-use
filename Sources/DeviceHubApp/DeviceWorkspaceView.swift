import AppKit
import SwiftUI

/// The navigation sidebar, the device stage and a floating glass panel, all kept inside the window.
///
/// The panel floats over the stage's trailing edge instead of taking a split pane, so the stage
/// background runs beneath it and shows through the glass. The stage's content is inset by the
/// panel's width, so the device itself is never covered.
struct DeviceWorkspaceView<Sidebar: View, Detail: View, Panel: View>: View {
    let showsPanel: Bool
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail
    @ViewBuilder var panel: Panel

    @AppStorage("inspector.width") private var storedPanelWidth: Double = 400
    @State private var dragStartWidth: CGFloat?

    static var previewMinimumWidth: CGFloat { 300 }
    static var panelMinimumWidth: CGFloat { 340 }
    /// Space between the floating panel and the edges of the stage.
    static var panelMargin: CGFloat { 10 }
    static var panelCornerRadius: CGFloat { 22 }
    // The native split view needs room for its platform-specific divider.
    private let dividerWidth = NSSplitView().dividerThickness

    private var detailMinimumWidth: CGFloat {
        Self.previewMinimumWidth + (showsPanel ? Self.panelMinimumWidth + 2 * Self.panelMargin : 0)
    }

    /// The stored width, limited so the stage always keeps its minimum width.
    private func panelWidth(in available: CGFloat) -> CGFloat {
        let maximum = max(Self.panelMinimumWidth, available - Self.previewMinimumWidth - 2 * Self.panelMargin)
        return min(max(CGFloat(storedPanelWidth), Self.panelMinimumWidth), maximum)
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
                    let width = panelWidth(in: available.size.width)
                    ZStack(alignment: .trailing) {
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // Views that ignore the safe area, like the stage background, still
                            // extend beneath the panel.
                            .safeAreaPadding(.trailing, showsPanel ? width + 2 * Self.panelMargin : 0)
                        if showsPanel {
                            floatingPanel(width: width, available: available.size.width)
                                .padding(Self.panelMargin)
                                // Callers animate the change, so layout stays deterministic.
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .frame(minWidth: detailMinimumWidth)
            }
        }
        .frame(minWidth: 940, minHeight: 680)
    }

    private func floatingPanel(width: CGFloat, available: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
        return panel
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipShape(shape)
            .glassSurface(in: shape)
            .overlay(alignment: .leading) { resizeHandle(available: available) }
    }

    /// Dragging the panel's leading edge resizes it.
    private func resizeHandle(available: CGFloat) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: -4)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStartWidth ?? panelWidth(in: available)
                        dragStartWidth = start
                        storedPanelWidth = Double(start - drag.translation.width)
                        storedPanelWidth = Double(panelWidth(in: available))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .accessibilityHidden(true)
    }
}
