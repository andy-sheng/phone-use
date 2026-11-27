import AppKit
import SwiftUI

/// The navigation sidebar, the device stage and a floating glass panel, all kept inside the window.
///
/// The panel floats over the stage's trailing edge instead of taking a split pane, so the stage
/// background runs beneath it and shows through the glass. The stage's content is inset by the
/// panel's width, so the device itself is never covered.
struct DeviceWorkspaceView<Sidebar: View, Detail: View, Panel: View>: View {
    var isCompact = false
    var isResizingWindow = false
    let showsPanel: Bool
    var panelAtBottom = false
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail
    @ViewBuilder var panel: Panel

    @AppStorage("inspector.width") private var storedPanelWidth: Double = 400
    @AppStorage("inspector.height") private var storedPanelHeight = 320.0
    @State private var dragStartHeight: CGFloat?
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var expandedSidebarWidth: CGFloat = 250
    @State private var expandedColumns = NavigationSplitViewVisibility.all
    @State private var dragStartWidth: CGFloat?

    static var previewMinimumWidth: CGFloat { 300 }
    static var panelMinimumWidth: CGFloat { 340 }
    /// Space between the floating panel and the edges of the stage.
    static var panelMargin: CGFloat { 10 }
    static var panelCornerRadius: CGFloat { 22 }
    // The native split view needs room for its platform-specific divider.
    private let dividerWidth = NSSplitView().dividerThickness

    private var detailMinimumWidth: CGFloat {
        Self.previewMinimumWidth + (showsPanel && !panelAtBottom ? Self.panelMinimumWidth + 2 * Self.panelMargin : 0)
    }

    /// The stored width, limited so the stage always keeps its minimum width.
    private func panelWidth(in available: CGFloat) -> CGFloat {
        let maximum = max(Self.panelMinimumWidth, available - Self.previewMinimumWidth - 2 * Self.panelMargin)
        return min(max(CGFloat(storedPanelWidth), Self.panelMinimumWidth), maximum)
    }

    var body: some View {
        GeometryReader { window in
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        if !isCompact && !isResizingWindow && width >= 220 { expandedSidebarWidth = width }
                    }
                    .navigationSplitViewColumnWidth(
                        min: isResizingWindow ? expandedSidebarWidth : 220, ideal: expandedSidebarWidth,
                        max: max(isResizingWindow ? expandedSidebarWidth : 220,
                                 window.size.width - detailMinimumWidth - dividerWidth)
                    )
            } detail: {
                GeometryReader { available in
                    let width = panelWidth(in: available.size.width)
                    VStack(spacing: 0) {
                        ZStack(alignment: .trailing) {
                            detail
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .safeAreaPadding(.trailing, showsPanel && !panelAtBottom ? width + 2 * Self.panelMargin : 0)
                            if showsPanel && !panelAtBottom {
                                floatingPanel(width: width, available: available.size.width)
                                    .padding(Self.panelMargin)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        if showsPanel && panelAtBottom {
                            let height = panelHeight(storedPanelHeight, available: available.size.height)
                            panel
                                .frame(maxWidth: .infinity)
                                .frame(height: height)
                                .background(.background)
                                .overlay(alignment: .top) { horizontalDivider(height: height, available: available.size.height) }
                                .transition(.move(edge: .bottom))
                        }
                    }
                }
                .frame(minWidth: isCompact || isResizingWindow ? nil : detailMinimumWidth)
            }
        }
        .background {
            if isCompact { Color(nsColor: .underPageBackgroundColor).ignoresSafeArea() }
        }
        .onChange(of: isCompact) { _, compact in
            if compact { expandedColumns = columns }
            columns = compact ? .detailOnly : expandedColumns
        }
        .frame(minWidth: isCompact || isResizingWindow ? CompactLayout.minimumSize.width : 940,
               minHeight: isCompact || isResizingWindow ? CompactLayout.minimumSize.height - 60 : 680)
    }

    private func panelHeight(_ height: CGFloat, available: CGFloat) -> CGFloat {
        // Keep both the preview controls and the inspector usable when resizing the window.
        min(max(180, height), max(0, available - 220))
    }

    private func horizontalDivider(height: CGFloat, available: CGFloat) -> some View {
        Divider()
            .frame(height: 8)
            .contentShape(Rectangle())
            .offset(y: -4)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStartHeight ?? height
                    dragStartHeight = start
                    storedPanelHeight = panelHeight(start - drag.translation.height, available: available)
                }
                .onEnded { _ in dragStartHeight = nil })
            .accessibilityHidden(true)
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
