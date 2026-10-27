internal import EditorCore
private import Foundation
internal import CoveUI
internal import CoveUIRuntime

/// Project, focus, the Make and Agent switch, package tools and run controls on one 40pt row.
/// Lower-priority items step down as the window narrows; their order never changes.
struct EditorTitleBar: View {
    let app: EditorApplication
    let width: Float
    var menuPresentation: EditorMenuPresentation = .current
    let onCommand: (EditorCommand) -> Void
    private var documents: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    private var workbench: Observed<WorkbenchSession, WorkbenchCatalog>
    private var projects: Observed<EditorLaunchContext, [EditorProjectEntry]>?

    init(app: EditorApplication, width: Float, menuPresentation: EditorMenuPresentation = .current,
         projects: EditorLaunchContext? = nil, onCommand: @escaping (EditorCommand) -> Void) {
        self.app = app
        self.width = width
        self.projects = projects.map { Observed(\.projects, on: $0) }
        self.menuPresentation = menuPresentation
        self.onCommand = onCommand
        documents = Observed(\.snapshot, on: app.workstation.documents)
        workbench = Observed(\.catalog, on: app.workbench)
    }

    var body: some View {
        let store = app.store
        let focus = self.focus
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            ImmersiveWindowTitleBar(height: 40) {
                Row(alignment: .center, spacing: 10) {
                    if menuPresentation == .titleBar {
                        EditorTitleMenu(catalog: catalog, onCommand: onCommand).id("title-menu")
                    }
                    project.id("title-project")
                    EditorContentPicker(app: app, content: store.content, onCommand: onCommand).id("title-content")
                    if width >= 1180, let branch = EditorProjectBranch.name(in: app.projectDirectory) {
                        Row(alignment: .center, spacing: 4) {
                            Icon(UIIcons.Editor.gitBranch, size: 11, color: .onSurfaceMuted)
                            Text(branch, lineLimit: 1).truncated().font(.caption).foregroundColor(.onSurfaceMuted)
                                .frame(maxWidth: 110).clipped()
                        }.accessibility { $0.label = L("Branch") + " " + branch }.id("title-branch").debugName("editor-branch")
                    }
                    if width >= 1180 {
                        breadcrumb(focus).flex(0, shrink: 1).frame(minWidth: 0, maxWidth: 320).clipped().id("title-selection")
                    }
                    WindowDragRegion().flex().frame(minWidth: 8).id("title-drag")
                    // One view needs no switch; a second view appears only when
                    // a package declares one.
                    if app.studioViewSegments.count > 1 { EditorViewSwitch(host: app).id("title-view") }
                    WindowDragRegion().flex().frame(minWidth: 8).id("title-drag-fill")
                    if width >= 900, !workbench.wrappedValue.toolbarItems.isEmpty {
                        PluginToolbar(items: workbench.wrappedValue.toolbarItems, onCommand: onCommand).id("title-plugins")
                    }
                    EditorPlaybackToolbar(state: store.playbackState, compact: width < 520, showsTarget: width >= 1400,
                                          onCommand: onCommand)
                        .id("title-playback")
                }
                // The shell adds its own drag region after this row, and both grow
                // equally. A full-width basis that shrinks to fit claims all free
                // space, so the trailing controls reach the window edge.
                .frame(width: .percent(100), minWidth: 0).flex(1, shrink: 1)
            }
        }
        .frame(height: 40).debugName("editor-title-bar")
    }

    /// Reads the observed values the catalog depends on, so the title-bar menu
    /// refreshes with selection, history, playback and the open document.
    private var catalog: EditorCommandCatalog {
        let store = app.store
        let _ = store.sceneRevision
        let _ = documents.wrappedValue
        let _ = workbench.wrappedValue
        let _ = (store.content, store.playbackState, store.selectedEntityIDs)
        return .make(EditorCommandContext(app: app))
    }

    // MARK: Project

    @ViewBuilder private var project: some View {
        // An untitled workspace has no project to name, so the chip is absent
        // rather than reading "Untitled".
        if !app.isUntitledWorkspace {
            if let projects {
                MenuButton(entries: projectEntries(projects.wrappedValue), width: 240,
                           accessibilityLabel: L("Projects")) { projectLabel }
                    .buttonStyle(EditorChromeButtonStyle()).debugName("editor-project")
            } else {
                Button(tooltip: L("Project commands")) {
                    onCommand(.showCommandPalette(.commands))
                } label: { projectLabel }.buttonStyle(EditorChromeButtonStyle()).debugName("editor-project")
            }
        }
    }

    /// The window's projects, with the one in front checked, then opening and closing.
    private func projectEntries(_ list: [EditorProjectEntry]) -> [MenuEntry] {
        list.filter { !EditorScratchWorkspace.isScratch($0.directory) }.map { entry in
            .item(MenuItem(id: "project:" + entry.directory, title: entry.name,
                           isSelected: entry.directory == app.projectDirectory,
                           action: { onCommand(.activateProject(entry.directory)) }))
        } + [
            .separator("project-separator"),
            .item(MenuItem(id: "project.open", title: L("Open Folder..."),
                           shortcut: EditorCommandCatalog.openFolderShortcut.label,
                           action: { onCommand(.openFolder) })),
            .item(MenuItem(id: "project.close", title: L("Close Project"), action: { onCommand(.closeProject) })),
        ]
    }

    private var projectLabel: some View {
        let name = projects?.wrappedValue.first { $0.directory == app.projectDirectory }?.name
            ?? URL(fileURLWithPath: app.projectDirectory).lastPathComponent
        return Row(alignment: .center, spacing: 7) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(Self.initials(of: name)).font(.caption).foregroundColor(Color(red: 0x10, green: 0x24, blue: 0x1A))
            }
            .frame(width: 22, height: 22)
            .background(UILinearGradient(Color(red: 0x5F, green: 0xAF, blue: 0x82),
                                         EditorThemeTokens.defaultValue.assistant, angle: 135))
            .cornerRadius(6)
            .debugName("editor-project-mark")
            if width >= 800 {
                Text(name, lineLimit: 1).font(.bodyStrong).frame(maxWidth: 150)
                Icon(UIIcons.Navigation.chevronDown, size: 9, color: .onSurfaceMuted)
            }
        }
    }

    /// "CrystalRush" → "CR", "my game" → "MG", "demo" → "DE".
    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        var letters = words.compactMap(\.first)
        if letters.count < 2, let word = words.first {
            letters = word.filter(\.isUppercase).map { $0 }
            if letters.count < 2 { letters = Array(word.prefix(2)) }
        }
        return String(letters.prefix(2)).uppercased()
    }

    // MARK: Focus

    private var focus: EditorWorkFocus { EditorWorkFocus(app: app, documents: documents.wrappedValue) }

    private func breadcrumb(_ focus: EditorWorkFocus) -> some View {
        Row(alignment: .center, spacing: 5) {
            for (index, part) in focus.trail.enumerated() {
                if index > 0 { AnyView(Icon(UIIcons.Navigation.chevronRight, size: 9, color: .onSurfaceMuted)) }
                AnyView(Text(part, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted))
            }
            if let leaf = focus.leaf {
                if !focus.trail.isEmpty { Icon(UIIcons.Navigation.chevronRight, size: 9, color: .onSurfaceMuted) }
                if let path = focus.leafPath { FileIcon(path: path, size: 13) }
                else if let icon = focus.leafIcon { Icon(icon, size: 12, color: .onSurfaceVariant) }
                Text(leaf, lineLimit: 1).font(.caption).foregroundColor(.onSurface)
                if focus.isDirty {
                    Box {}.frame(width: 6, height: 6).background(.warning).cornerRadius(3)
                        .accessibility { $0.label = L("Unsaved") }
                }
            }
        }.debugName("editor-breadcrumb")
    }

}

/// The checked-out branch of the repository containing the project, read from
/// `.git/HEAD` and refreshed at most every few seconds.
enum EditorProjectBranch {
    nonisolated(unsafe) private static var cache: [String: (checked: Date, name: String?)] = [:]

    static func name(in projectDirectory: String) -> String? {
        if let entry = cache[projectDirectory], Date().timeIntervalSince(entry.checked) < 5 { return entry.name }
        let name = read(from: URL(fileURLWithPath: projectDirectory))
        cache[projectDirectory] = (Date(), name)
        return name
    }

    private static func read(from start: URL) -> String? {
        var directory = start.standardizedFileURL
        for _ in 0..<8 {
            let git = directory.appendingPathComponent(".git")
            var head = git.appendingPathComponent("HEAD")
            if let pointer = try? String(contentsOf: git, encoding: .utf8), pointer.hasPrefix("gitdir:") {
                let path = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                head = URL(fileURLWithPath: path, relativeTo: directory).appendingPathComponent("HEAD")
            }
            if let text = try? String(contentsOf: head, encoding: .utf8) {
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst("ref: refs/heads/".count)) }
                return String(line.prefix(7))
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
        return nil
    }
}
