import GuavaUICompose

struct _WorkspaceLayoutNodeView: View {
    let node: WorkspaceLayoutNode
    let slotID: WorkspaceSlotID
    let document: WorkspaceDocument
    let controller: WorkspaceController
    let content: (WorkspacePanelID) -> AnyView

    @ViewBuilder var body: some View {
        switch node {
        case .group(let groupID):
            if let group = document.groups[groupID] {
                _WorkspaceTabGroupView(group: group, document: document, controller: controller, content: content)
                    .id(group.id).flex().frame(minWidth: 0, minHeight: 0)
            } else { EmptyView().flex() }
        case .split(let axis, let fraction, let first, let second):
            if let firstID = first.leafGroupIDs.first, let secondID = second.leafGroupIDs.first {
                let address = WorkspaceLayoutSplit(slot: slotID, firstGroup: firstID, secondGroup: secondID)
                SplitView(axis == .horizontal ? .horizontal : .vertical,
                          fraction: Binding(get: { fraction }, set: {
                              _ = controller.dispatch(.resizeLayoutSplit(address, fraction: $0))
                          }), constraints: .init(fraction: 0.05...0.95)) {
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
