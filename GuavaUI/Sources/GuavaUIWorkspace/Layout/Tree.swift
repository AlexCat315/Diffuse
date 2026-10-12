import GuavaUICompose

struct _WorkspaceLayoutNodeView: View {
    let node: WorkspaceLayoutNode
    let slotID: WorkspaceSlotID
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    var body: some View {
        WorkspaceMetricsReader { metrics in resolvedBody(metrics: metrics) }
    }

    @ViewBuilder private func resolvedBody(metrics: WorkspaceLayoutMetrics) -> some View {
        switch node {
        case .group(let groupID):
            if let group = document.groups[groupID] {
                _WorkspaceTabGroupView(group: group, document: document, controller: controller, content: content)
                    .id(group.id).flex().frame(minWidth: 0, minHeight: 0)
            } else { EmptyView().flex() }
        case .split(let axis, let fraction, let first, let second):
            if let firstID = first.leafGroupIDs.first, let secondID = second.leafGroupIDs.first {
                let address = WorkspaceLayoutSplit(slot: slotID, firstGroup: firstID, secondGroup: secondID)
                let resolver = WorkspaceSizingResolver(document: document, metrics: metrics)
                let firstSize = resolver.layout(first, axis: axis)
                let secondSize = resolver.layout(second, axis: axis)
                SplitView(axis == .horizontal ? .horizontal : .vertical,
                          fraction: Binding(get: { fraction }, set: {
                              _ = controller.dispatch(.resizeLayoutSplit(address, fraction: $0))
                          }), dividerThickness: metrics.divider,
                          constraints: .init(fraction: 0...1,
                              minimumFirst: firstSize.minimum, minimumSecond: secondSize.minimum,
                              maximumFirst: firstSize.maximum, maximumSecond: secondSize.maximum)) {
                    _WorkspaceLayoutNodeView(node: first, slotID: slotID, document: document,
                                             controller: controller, content: content)
                } second: {
                    _WorkspaceLayoutNodeView(node: second, slotID: slotID, document: document,
                                             controller: controller, content: content)
                }
                .frame(minWidth: 0, minHeight: 0)
                .layoutRole("workspace-split")
                .semanticRole("workspace.split.\(axis.rawValue)")
                .debugName("workspace-layout-split-\(slotID.rawValue)-\(firstID.rawValue)-\(secondID.rawValue)")
            }
        }
    }
}
