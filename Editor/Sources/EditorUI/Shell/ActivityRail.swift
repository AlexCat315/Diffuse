internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime
internal import CoveUIWorkspace

/// The one switcher for the left side: each entry picks the sidebar's view,
/// and picking the showing one again folds the sidebar away.
struct EditorActivityRail: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let onCommand: (EditorCommand) -> Void
    private var layout: Observed<WorkspaceController, UInt64>
    private var selection: Observed<EditorSidebar, WorkspacePanelID>

    init(app: EditorApplication, controller: WorkspaceController, onCommand: @escaping (EditorCommand) -> Void) {
        self.app = app
        self.controller = controller
        self.onCommand = onCommand
        layout = Observed(\.version, on: controller)
        selection = Observed(\.selection, on: EditorSidebar.of(controller))
    }

    var body: some View {
        let _ = layout.wrappedValue
        Column(alignment: .center, spacing: 0) {
            view(UIIcons.Text.list, title: L("Outline"), id: "hierarchy")
            view(UIIcons.File.folder, title: L("Files"), id: "files")
            action(UIIcons.Action.search, title: L("Search")) {
                onCommand(.showCommandPalette(.resources))
            }.debugName("editor-rail-search")
            SourceControlRailButton(app: app, isSelected: isShowing("source-control")) {
                onCommand(.togglePanel("source-control"))
            }
            if app.workstation.tasks.snapshot.isAvailable {
                view(UIIcons.Editor.box, title: L("Tasks"), id: "tasks")
            }
            view(UIIcons.File.package, title: L("Assets"), id: "assets")
            for panel in app.workbenchCatalog.panels where panel.slot == WorkspaceSlotID.leading.rawValue && panel.inSurface == nil && panel.surface == nil {
                AnyView(view(panel.icon.map { .svg(named: $0, in: EditorAppResourceBundle.bundle, subdirectory: "PanelIcons") }
                                 ?? UIIcons.Layout.panelLeft,
                             title: panel.title, id: WorkspacePanelID(rawValue: panel.id)))
            }
            Spacer(minLength: 0)
            action(UIIcons.Action.settings, title: L("Settings")) { onCommand(.openSettings) }
                .debugName("editor-rail-settings")
        }.padding(vertical: 8).frame(width: 44)
            .debugName("editor-activity-rail")
    }

    private func isShowing(_ id: WorkspacePanelID) -> Bool {
        guard selection.wrappedValue == id,
              let group = controller.document.groupContaining(panelID: EditorSidebar.panelID) else { return false }
        return !group.isCollapsed && controller.maximizedPanelID == nil
    }

    private func view(_ icon: BundleImageResource, title: String, id: WorkspacePanelID) -> some View {
        let selected = isShowing(id)
        return Button(icon: .resource(icon), size: 17, isSelected: selected, tooltip: title) {
            onCommand(.togglePanel(id.rawValue))
        }.buttonStyle(ActivityButtonStyle())
            .accessibility { $0.label = title; $0.state.isSelected = selected }
            .debugName("editor-rail-" + id.rawValue)
    }

    private func action(_ icon: BundleImageResource, title: String, perform: @escaping () -> Void) -> some View {
        Button(icon: .resource(icon), size: 17, tooltip: title, action: perform)
            .buttonStyle(ActivityButtonStyle())
            .accessibility { $0.label = title }
    }
}

private struct ActivityButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        Row(alignment: .center, spacing: 4) {
            Box {}.frame(width: 2, height: 16)
                .background(configuration.isSelected ? colors.accent : .clear).cornerRadius(1)
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                AnyView(configuration.label).foregroundColor(configuration.isSelected ? colors.onSurface : colors.onSurfaceVariant)
            }.frame(width: 32, height: 32)
                .background(configuration.isPressed ? colors.stateLayerPressed
                    : configuration.isSelected ? colors.surfaceVariant
                    : configuration.isHovered ? colors.stateLayerHover : .clear)
                .cornerRadius(8)
                .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
        }.padding(EdgeInsets(trailing: 6)).frame(width: 44, height: 36)
            .animation(motion: .fast, value: configuration.interactionKey)
    }
}


/// The Source Control entry carries the number of changed files.
private struct SourceControlRailButton: View {
    let app: EditorApplication
    let isSelected: Bool
    let action: () -> Void
    private let observed: Observed<EditorVersionControl, VersionControlSnapshot>

    init(app: EditorApplication, isSelected: Bool, action: @escaping () -> Void) {
        self.app = app
        self.isSelected = isSelected
        self.action = action
        observed = Observed(\.snapshot, on: app.workstation.versionControl)
    }

    var body: some View {
        let count = Set(observed.wrappedValue.status.changes.map(\.path)).count
        let title = L("Source Control")
        // The count sits on the tile's lower corner, ringed in the rail's
        // colour so it reads apart from the glyph rather than covering it.
        ZStack(alignment: .bottomTrailing) {
            Button(icon: .resource(UIIcons.Editor.gitBranch), size: 17, isSelected: isSelected, tooltip: title, action: action)
                .buttonStyle(ActivityButtonStyle())
            if count > 0 {
                Box {
                    Box {
                        Box(direction: .row, alignItems: .center, justifyContent: .center) {
                            Text(count > 99 ? "99+" : "\(count)", lineLimit: 1)
                                .font(.system(size: 9, weight: .semibold)).foregroundColor(.onAccent)
                        }.padding(horizontal: 3).frame(height: 14, minWidth: 14).background(.accent).cornerRadius(7)
                    }.padding(2).background(.background).cornerRadius(9)
                }.padding(EdgeInsets(bottom: 0, trailing: 2))
                .accessibilityHidden()
            }
        }
        .accessibility { $0.label = count > 0 ? "\(title), \(count)" : title; $0.state.isSelected = isSelected }
        .debugName("editor-rail-source-control")
    }
}
