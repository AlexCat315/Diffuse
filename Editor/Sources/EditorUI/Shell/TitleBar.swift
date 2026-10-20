internal import EditorCore
internal import StudioDocuments
private import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// Project, focus, intent, Space, presence and run controls on one 40pt row.
/// Lower-priority items step down as the window narrows; their order never changes.
struct EditorTitleBar: View {
    let app: EditorApplication
    let width: Float
    var menuPresentation: EditorMenuPresentation = .current
    let onCommand: (EditorCommand) -> Void
    private var documents: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>

    init(app: EditorApplication, width: Float, menuPresentation: EditorMenuPresentation = .current,
         onCommand: @escaping (EditorCommand) -> Void) {
        self.app = app
        self.width = width
        self.menuPresentation = menuPresentation
        self.onCommand = onCommand
        documents = Observed(\.snapshot, on: app.workstation.documents)
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
                    if width >= 1180, let branch = EditorProjectBranch.name(in: app.projectDirectory) {
                        Row(alignment: .center, spacing: 4) {
                            Icon(UIIcons.Editor.gitBranch, size: 11, color: .onSurfaceMuted)
                            Text(branch, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted).frame(maxWidth: 90)
                        }.accessibility { $0.label = L("Branch") + " " + branch }.id("title-branch").debugName("editor-branch")
                    }
                    if width >= 1180 {
                        breadcrumb(focus).flex(0, shrink: 1).frame(minWidth: 0, maxWidth: 320).clipped().id("title-selection")
                    }
                    WindowDragRegion().frame(width: 8).id("title-drag")
                    // The intent field takes the room left between focus and Spaces.
                    if width >= 1100 {
                        intent(focus).frame(minWidth: 180, maxWidth: 560).flex(1, shrink: 1).id("title-intent")
                        WindowDragRegion().flex(0.001, shrink: 1).frame(minWidth: 8).id("title-drag-fill")
                    } else {
                        intent(focus).frame(width: 32).id("title-intent")
                        WindowDragRegion().flex().frame(minWidth: 8).id("title-drag-fill")
                    }
                    EditorSpaceSwitcher(mode: store.workspaceMode,
                                        presentation: width < 680 ? .menu : width < 1340 ? .icons : .labels,
                                        onCommand: onCommand).id("title-spaces")
                    if width >= 1100 { presence.id("title-presence") }
                    if store.workspaceMode.isGameWorkspace {
                        EditorPlaybackToolbar(state: store.playbackState, compact: width < 520, showsTarget: width >= 1400,
                                              onCommand: onCommand)
                            .id("title-playback")
                    }
                }.flex().frame(minWidth: 0)
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
        return .make(EditorCommandContext(workspaceMode: store.workspaceMode,
                                          layoutPreset: store.activeLayoutPreset,
                                          playbackState: store.playbackState,
                                          canUndo: app.canUndo,
                                          canRedo: app.canRedo,
                                          hasSelection: !store.selectedEntityIDs.isEmpty,
                                          document: EditorCommandDocument(app.workstation.documents)))
    }

    // MARK: Project

    private var project: some View {
        let name = URL(fileURLWithPath: app.projectDirectory).lastPathComponent
        return Button(tooltip: L("Project commands")) {
            onCommand(.showCommandPalette(.commands))
        } label: {
            Row(alignment: .center, spacing: 7) {
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    Text(Self.initials(of: name)).font(.caption).foregroundColor(Color(red: 0x10, green: 0x24, blue: 0x1A))
                }
                .frame(width: 22, height: 22)
                .background(UILinearGradient(Color(red: 0x5F, green: 0xAF, blue: 0x82),
                                             EditorChromeTokens.defaultValue.agent, angle: 135))
                .cornerRadius(6)
                .debugName("editor-project-mark")
                if width >= 800 {
                    Text(name, lineLimit: 1).font(.bodyStrong).frame(maxWidth: 150)
                    Icon(UIIcons.Navigation.chevronDown, size: 9, color: .onSurfaceMuted)
                }
            }
        }.buttonStyle(EditorChromeButtonStyle()).debugName("editor-project")
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

    /// What the window is working on: the open document in text Spaces, the
    /// selected entity in scene Spaces.
    private struct Focus {
        var rootIcon: BundleImageResource
        var trail: [String]
        var leaf: String?
        var leafIcon: BundleImageResource?
        var isDirty = false
    }

    private var focus: Focus {
        let features = app.store.workspaceMode.profile.features
        if !features.contains(.scene) {
            let snapshot = documents.wrappedValue
            guard let path = snapshot.selectedPath else {
                return Focus(rootIcon: UIIcons.File.folder, trail: [L("Files")])
            }
            let parts = path.split(separator: "/").map(String.init)
            let document = snapshot.selected
            return Focus(rootIcon: UIIcons.File.folder, trail: Array(parts.dropLast()), leaf: parts.last,
                         leafIcon: DocumentKind(path: path).icon, isDirty: document?.isDirty == true)
        }
        let entity = app.scene.entitySummary(id: app.store.selectedEntityID)
        return Focus(rootIcon: UIIcons.Shape.globe, trail: [L("Scene")], leaf: entity?.name,
                     leafIcon: entity == nil ? nil : UIIcons.Editor.box)
    }

    private func breadcrumb(_ focus: Focus) -> some View {
        Row(alignment: .center, spacing: 5) {
            Icon(focus.rootIcon, size: 12, color: .onSurfaceMuted)
            for (index, part) in focus.trail.enumerated() {
                if index > 0 { AnyView(Icon(UIIcons.Navigation.chevronRight, size: 9, color: .onSurfaceMuted)) }
                AnyView(Text(part, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted))
            }
            if let leaf = focus.leaf {
                if !focus.trail.isEmpty { Icon(UIIcons.Navigation.chevronRight, size: 9, color: .onSurfaceMuted) }
                if let icon = focus.leafIcon { Icon(icon, size: 12, color: .onSurfaceVariant) }
                Text(leaf, lineLimit: 1).font(.caption).foregroundColor(.onSurface)
                if focus.isDirty {
                    Box {}.frame(width: 6, height: 6).background(.warning).cornerRadius(3)
                        .accessibility { $0.label = L("Unsaved") }
                }
            }
        }.debugName("editor-breadcrumb")
    }

    // MARK: Intent

    private func intent(_ focus: Focus) -> some View {
        let shortcut = catalog.entries.first { $0.id == "agent.intent" }?.shortcut?.label ?? ""
        return Button(tooltip: L("Tell Guava what you want to do…")) {
            onCommand(.showCommandPalette(.intent))
        } label: {
            Row(alignment: .center, spacing: 7) {
                Icon(UIIcons.Status.sparkles, size: 13, color: EditorChromeTokens.agentColor)
                if width >= 1100 {
                    Text(L("Tell Guava what you want to do…"), lineLimit: 1)
                        .font(.caption).foregroundColor(.onSurfaceMuted).flex(1, shrink: 1).frame(minWidth: 0)
                    if let leaf = focus.leaf {
                        Text("@" + leaf).truncated().font(.caption).foregroundColor(.onSurfaceVariant)
                            .frame(maxWidth: 140)
                            .padding(horizontal: 6).frame(height: 18)
                            .background(.surfaceVariant).cornerRadius(4).flex(0, shrink: 1)
                            .debugName("editor-intent-context")
                    }
                    Text(shortcut).font(.caption)
                        .foregroundColor(.onSurfaceMuted).padding(horizontal: 4)
                        .border(.borderStrong, width: 1).cornerRadius(3)
                }
            }.padding(EdgeInsets(leading: 9, trailing: 6)).frame(width: .percent(100), height: .points(28), minWidth: 0)
                .background(.surfaceSunken).cornerRadius(8).border(.borderStrong, width: 1)
        }.buttonStyle(.plain).frame(width: .percent(100)).debugName("editor-intent-bar")
    }

    // MARK: Presence

    /// Who is working in this project: you, and Guava with a ring while it works.
    private var presence: some View {
        let working = app.store.agentTasks.contains { $0.phase == .planning }
        // Two overlapping avatars; the surface-coloured ring separates them.
        return ZStack(alignment: .leading) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(L("You"), lineLimit: 1).font(.caption).foregroundColor(Color(red: 0xDD, green: 0xF2, blue: 0xE5))
            }
            .frame(width: 24, height: 24).background(Color(red: 0x3C, green: 0x6E, blue: 0x55)).cornerRadius(12)
            .border(.surface, width: 2)
            .accessibility { $0.label = L("You") }
            // Padding a styled box would move only its content; the wrapper moves the circle.
            Box(direction: .row, alignItems: .center, spacing: 0) {
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    Icon(UIIcons.Status.sparkles, size: 11, color: EditorChromeTokens.agentColor)
                }
                .frame(width: 24, height: 24).background(Color(red: 0x5A, green: 0x29, blue: 0x34)).cornerRadius(12)
                .border(working ? EditorChromeTokens.agentColor : .surface, width: 2)
                .accessibility { $0.label = working ? L("Guava is working") : "Guava" }
            }.padding(EdgeInsets(leading: 17))
        }.frame(width: 41, height: 24).debugName("editor-presence")
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
