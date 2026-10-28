internal import EditorCore
internal import EngineKernel
internal import CoveUI

/// Everything a command's availability depends on. The native menu rebuilds
/// only when this value changes.
struct EditorCommandContext: Equatable {
    var content: EditorContent
    var playbackState: PlaybackState = .stopped
    var canUndo = false
    var canRedo = false
    var hasSelection = false
    /// The editor's selected text document, when one is open.
    var document: EditorCommandDocument?
    /// Commands and panels of the enabled packages.
    var workbench: WorkbenchCatalog = .empty
    /// The panel that holds the agent conversation, while an agent is enabled.
    var agentPanelID: String?

    init(content: EditorContent,
         playbackState: PlaybackState = .stopped,
         canUndo: Bool = false,
         canRedo: Bool = false,
         hasSelection: Bool = false,
         document: EditorCommandDocument? = nil,
         workbench: WorkbenchCatalog = .empty,
         agentPanelID: String? = nil) {
        self.content = content
        self.playbackState = playbackState
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.hasSelection = hasSelection
        self.document = document
        self.workbench = workbench
        self.agentPanelID = agentPanelID
    }

    init(app: EditorApplication) {
        let state = app.store.state
        self.init(content: state.content,
                  playbackState: state.timing.playbackState,
                  canUndo: app.canUndo,
                  canRedo: app.canRedo,
                  hasSelection: !state.selection.selectedEntityIDs.isEmpty,
                  document: EditorCommandDocument(app.workstation.documents),
                  workbench: app.workbenchCatalog,
                  agentPanelID: app.agentPanelID)
    }
}

struct EditorCommandDocument: Equatable {
    var isDirty: Bool

    init(isDirty: Bool) { self.isDirty = isDirty }

    init?(_ model: EditorDocumentWorkspace) {
        guard let path = model.selectedPath, let document = model.documents.first(where: { $0.path == path }) else { return nil }
        isDirty = document.isDirty
    }
}

struct EditorCommandEntry {
    /// Stable identifier used by the palette and tests.
    let id: String
    let title: String
    var keywords = ""
    var shortcut: EditorShortcut?
    let command: EditorCommand
    var isEnabled = true
    var isSelected = false
    /// Entries that only open the palette itself stay out of its results.
    var inPalette = true
}

enum EditorCommandItem {
    case entry(EditorCommandEntry)
    case submenu(EditorCommandMenu)
    case separator
}

struct EditorCommandMenu {
    let id: String
    let title: String
    var items: [EditorCommandItem]
}

/// The one command tree. The macOS menu bar, the Windows/Linux title-bar menu,
/// the command palette and keyboard shortcuts are all projections of it.
struct EditorCommandCatalog {
    /// ⌘O opens a scene, so folders take ⌘⇧O.
    static let openFolderShortcut = EditorShortcut(.letter("o"), [.primary, .shift])

    /// About and Settings. macOS places them in the application menu; other
    /// presentations fold them into Help and Edit.
    let applicationItems: [EditorCommandItem]
    let menus: [EditorCommandMenu]
    /// Package commands. They have no menu placement, so only the palette lists them.
    let contributed: [EditorCommandEntry]

    static func make(_ context: EditorCommandContext) -> Self {
        let builder = Builder(context: context)
        return Self(applicationItems: builder.applicationItems,
                    menus: builder.menus.compactMap { $0.filtered(for: context.content) },
                    contributed: builder.contributed)
    }

    /// Menus for a presentation without an application menu.
    var menusWithApplicationItems: [EditorCommandMenu] {
        let about = applicationItems.filter { $0.entry?.command.isAbout == true }
        let settings = applicationItems.filter { $0.entry?.command.isAbout == false }
        return menus.map { menu in
            var menu = menu
            switch menu.id {
            case "edit" where !settings.isEmpty: menu.items += [.separator] + settings
            case "help" where !about.isEmpty: menu.items += [.separator] + about
            default: break
            }
            return menu
        }
    }

    /// Every entry in menu order, including nested submenus.
    var entries: [EditorCommandEntry] {
        (applicationItems + menus.map { .submenu($0) }).flatMap(\.entries) + contributed
    }

    func entry(matching event: KeyEvent) -> EditorCommandEntry? {
        entries.first { $0.shortcut?.matches(event) == true }
    }

    /// A chord that is unavailable only because the game is running. Bare keys
    /// such as Delete stay silent: during play they usually belong to the game.
    static func isBlockedOnlyByPlayback(_ entry: EditorCommandEntry, in context: EditorCommandContext) -> Bool {
        guard context.playbackState != .stopped, !entry.isEnabled,
              entry.shortcut?.modifiers.isEmpty == false else { return false }
        var stopped = context
        stopped.playbackState = .stopped
        return make(stopped).entries.contains { $0.id == entry.id && $0.isEnabled }
    }
}

private extension EditorCommandItem {
    var entry: EditorCommandEntry? {
        if case let .entry(entry) = self { return entry }
        return nil
    }

    var entries: [EditorCommandEntry] {
        switch self {
        case let .entry(entry): [entry]
        case let .submenu(menu): menu.items.flatMap(\.entries)
        case .separator: []
        }
    }
}

private extension EditorCommand {
    var isAbout: Bool {
        if case .about = self { return true }
        return false
    }
}

private extension EditorCommandMenu {
    /// Drops commands the workspace does not authorize, then collapses empty
    /// submenus and redundant separators so no menu shows dead structure.
    func filtered(for content: EditorContent) -> Self? {
        var kept: [EditorCommandItem] = []
        for item in items {
            switch item {
            case let .entry(entry):
                guard EditorWorkspaceCommandPolicy.allows(entry.command, in: content) else { continue }
                kept.append(item)
            case let .submenu(menu):
                guard let menu = menu.filtered(for: content) else { continue }
                kept.append(.submenu(menu))
            case .separator:
                guard !kept.isEmpty else { continue }
                if case .separator = kept.last { continue }
                kept.append(item)
            }
        }
        if case .separator = kept.last { kept.removeLast() }
        return kept.isEmpty ? nil : Self(id: id, title: title, items: kept)
    }
}

private struct Builder {
    let context: EditorCommandContext

    private var canAuthorScene: Bool {
        EditorSceneAuthoringPolicy.canEditScene(during: context.playbackState)
    }

    var applicationItems: [EditorCommandItem] {
        [
            entry("app.about", "About Cove", command: .about),
            entry("preferences", "Settings...", "preferences settings 设置 偏好", .init(.comma), command: .openSettings),
        ]
    }

    var menus: [EditorCommandMenu] {
        // The agent is a plugin. With it disabled its menu must not exist at
        // all — no title, no "Set up Assistant", no shortcut into a view that
        // has nothing behind it.
        let core = [file, edit, select, world, view]
        let tail = [run, window, help]
        return (core + (agentMenu.map { [$0] } ?? []) + tail).map(placingContributions)
    }

    /// Package commands no menu holds; the menus already feed the palette the rest.
    var contributed: [EditorCommandEntry] {
        let placed = Set(context.workbench.menuItems.map(\.command.id))
        return context.workbench.commands.filter { !placed.contains($0.id) }.map(pluginEntry)
    }

    /// Package commands a menu holds follow the host's items.
    private func placingContributions(_ menu: EditorCommandMenu) -> EditorCommandMenu {
        let items = context.workbench.menuItems.filter { $0.menu == menu.id }
        guard !items.isEmpty else { return menu }
        var menu = menu
        menu.items += [.separator] + items.map { .entry(pluginEntry($0.command)) }
        return menu
    }

    private func pluginEntry(_ command: ContributedCommand) -> EditorCommandEntry {
        EditorCommandEntry(id: "plugin." + command.id, title: command.title, keywords: command.keywords,
                           command: .plugin(pluginID: command.pluginID, name: command.name),
                           inPalette: command.showsInPalette)
    }

    private var file: EditorCommandMenu {
        menu("file", "File", [
            entry("scene.new", "New Scene", "new scene 新建场景", .init(.letter("n")), command: .newScene,
                  enabled: canAuthorScene),
            entry("scene.open", "Open Scene...", "open scene 打开场景", .init(.letter("o")), command: .openScene,
                  enabled: canAuthorScene),
            entry("search.resources", "Open Resource...", "", .init(.letter("p")),
                  command: .showCommandPalette(.resources), inPalette: false),
            entry("scene.save", "Save Scene", "save scene 保存场景", .init(.letter("s")), command: .saveScene),
            entry("document.save", "Save", "save file document 保存 文件", .init(.letter("s")), command: .saveDocument,
                  enabled: context.document?.isDirty == true),
            entry("document.revert", "Discard Changes", "revert discard reload 放弃修改 还原", command: .revertDocument,
                  enabled: context.document?.isDirty == true),
            entry("document.close", "Close File", "close file 关闭文件", .init(.letter("w")), command: .closeDocument,
                  enabled: context.document.map { !$0.isDirty } ?? false),
            .separator,
            entry("assets.import", "Import Assets...", "import assets 导入资源", command: .importAssets,
                  enabled: canAuthorScene),
            .separator,
            entry("project.open", "Open Folder...", "open folder project 打开 文件夹 项目", EditorCommandCatalog.openFolderShortcut,
                  command: .openFolder, enabled: EditorLaunchContext.current != nil),
            entry("project.close", "Close Project", "close project 关闭项目", command: .closeProject),
        ])
    }

    private var edit: EditorCommandMenu {
        menu("edit", "Edit", [
            entry("edit.undo", "Undo", "undo 撤销", .init(.letter("z")), command: .undo,
                  enabled: canAuthorScene && context.canUndo),
            entry("edit.redo", "Redo", "redo 重做", .init(.letter("z"), [.primary, .shift]), command: .redo,
                  enabled: canAuthorScene && context.canRedo),
            .separator,
            entry("edit.duplicate", "Duplicate Selection", "duplicate 复制", .init(.letter("d")),
                  command: .duplicateSelection, enabled: canAuthorScene && context.hasSelection),
            entry("edit.delete", "Delete Selection", "delete 删除", .init(.delete, []), command: .deleteSelection,
                  enabled: canAuthorScene && context.hasSelection),
        ])
    }

    private var select: EditorCommandMenu {
        let canSelect = canAuthorScene
        return menu("select", "Select", [
            entry("select.all", "Select All", "select all entities 全选", command: .selectAll, enabled: canSelect),
            entry("select.none", "Deselect", "clear selection 取消选择", command: .clearSelection,
                  enabled: context.hasSelection),
            entry("select.invert", "Invert Selection", "invert selection 反选", command: .invertSelection,
                  enabled: canSelect),
            .separator,
            entry("select.descendants", "Select Descendants", "children descendants 子级", command: .selectDescendants,
                  enabled: context.hasSelection),
        ])
    }

    private var world: EditorCommandMenu {
        let canEdit = canAuthorScene && context.hasSelection
        let templates: [EditorCommandItem] = EditorEntityTemplate.allCases.map { template in
            entry("world.add." + template.rawValue, template.displayName, "add create entity 添加 创建 实体",
                  command: .spawnEntity(template), enabled: canAuthorScene)
        }
        return menu("world", "World", [
            .submenu(menu("add-entity", "Add Entity", templates)),
            .submenu(menu("add-geometry", "Add Geometry", EditorGeometryPreset.allCases.map { preset in
                entry("world.geometry." + preset.rawValue,preset.displayName,"\(preset.displayName) mesh curve geometry modeling 建模 几何 曲线",
                      command: .createGeometry(preset),enabled: canAuthorScene)
            })),
            .separator,
            entry("world.frame", "Frame Selected", "frame focus 聚焦", command: .frameSelection,
                  enabled: context.hasSelection),
            entry("world.visibility", "Toggle Visibility", "hide show 隐藏 显示", command: .toggleSelectionVisibility,
                  enabled: canEdit),
            entry("world.lock", "Toggle Lock", "lock unlock 锁定 解锁", command: .toggleSelectionLock,
                  enabled: canEdit),
            .separator,
            entry("scene.settings", "Scene Settings", "physics scene 场景物理设置", command: .showSceneSettings),
        ])
    }

    private var view: EditorCommandMenu {
        let contents: [EditorCommandItem] = EditorContent.allCases.enumerated().map { index, content in
            entry("content." + content.rawValue, content.title, "show content 内容 场景 文件 时间线",
                  .init(.digit(index + 1)), command: .showContent(content), selected: context.content == content)
        }
        let surfaces: [EditorCommandItem] = context.workbench.panels.compactMap { panel in
            guard let surface = panel.surface else { return nil }
            let id = panel.pluginID + "." + surface
            return entry("surface." + id, panel.title, "view 视图", command: .showView(EditorStudioView(id)))
        }
        return menu("view", "View", contents + surfaces + [
            .separator,
            .submenu(menu("layout", "Layout", [
                entry("layout.save", "Save Layout", "layout workspace 保存布局", command: .saveLayout),
                entry("layout.reset", "Reset Layout", "layout workspace 重置布局", .init(.digit(0)),
                      command: .resetLayout),
            ])),
            .submenu(menu("panels", "Panels", [
                entry("area.leading", "Toggle Left Sidebar", "sidebar left panel hide show 左侧栏 侧边栏 显示 隐藏",
                      .init(.letter("l"), [.primary, .option]), command: .togglePanelArea(.leading)),
                entry("area.trailing", "Toggle Right Sidebar", "sidebar right panel hide show 右侧栏 侧边栏 显示 隐藏",
                      .init(.letter("r"), [.primary, .option]), command: .togglePanelArea(.trailing)),
                entry("area.bottom", "Toggle Bottom Panel", "bottom panel console hide show 底部面板 控制台 显示 隐藏",
                      .init(.letter("j")), command: .togglePanelArea(.bottom)),
            ])),
            .separator,
            entry("layout.viewport", "Maximize Viewport", "maximize 最大化视口", command: .maximizePanel("viewport")),
            entry("layout.documents", "Maximize Editor", "maximize code script 最大化编辑器 脚本", command: .maximizePanel("documents")),
            entry("layout.restore", "Restore Panels", "maximize restore 恢复面板", command: .restorePanels),
            .separator,
            entry("palette.commands", "Command Palette", "", .init(.letter("p"), [.primary, .shift]),
                  command: .showCommandPalette(.commands), inPalette: false),
            entry("theme.toggle", "Toggle Theme", "dark light theme 主题", command: .toggleTheme),
        ])
    }

    /// Nil while no agent plugin is enabled: the editor contributes no agent
    /// menu of its own.
    private var agentMenu: EditorCommandMenu? {
        // Pending reviews sit at the top of the Agent thread, so one entry serves both.
        guard context.agentPanelID != nil else { return nil }
        return menu("agent", "Agent", [
            entry("agent.intent", "Ask Cove...", "", .init(.letter("k")), command: .focusAssistant, inPalette: false),
            entry("agent.show", "Agent", "agent assistant conversation review approval 智能体 对话 审阅",
                  command: .showView(.agent)),
            entry("view.toggle", "Switch Workbench and Agent", "workbench agent view switch 工作台 智能体 视图 切换",
                  .init(.backslash), command: .toggleView),
        ])
    }

    private var run: EditorCommandMenu {
        let state = context.playbackState
        func transport(_ target: PlaybackState, _ title: String, _ shortcut: EditorShortcut? = nil) -> EditorCommandItem {
            entry("playback." + target.rawValue, title, "game preview 游戏试玩", shortcut, command: .setPlaybackState(target),
                  enabled: EditorPlaybackCommandPolicy.canTransition(from: state, to: target),
                  selected: state == target)
        }
        return menu("run", "Run", [
            entry("playback.toggle", "Play / Pause", "play pause game 试玩 暂停", .init(.enter),
                  command: .togglePlayback),
            transport(.playing, "Play"),
            transport(.paused, "Pause"),
            transport(.stopped, "Stop", .init(.enter, [.primary, .shift])),
            .separator,
            entry("project.build", "Build Project", "export build 导出构建", .init(.letter("b")),
                  command: .buildProject),
            entry("project.run", "Build and Run", "export run 构建运行", .init(.letter("r")),
                  command: .buildAndRun),
            .separator,
            entry("task.build", "Run Build Task", "task build compile swift package 任务 构建 编译", command: .runTask(.build)),
            entry("task.test", "Run Tests", "task test xctest testing 任务 测试", .init(.letter("u")),
                  command: .runTask(.test)),
        ])
    }

    private var window: EditorCommandMenu {
        func panel(_ id: String, keywords: String = "") -> EditorCommandItem {
            panelEntry("panel." + id, panel: id, keywords: "panel 面板 " + keywords, command: .showPanel(id))
        }
        return menu("window", "Window", [
            panel("hierarchy", keywords: "hierarchy outline 大纲 层级"),
            panel("files", keywords: "files explorer 文件"),
            panelEntry("inspector.show", panel: "inspector", keywords: "inspector properties 属性",
                       command: .showPanel("inspector")),
            panel("viewport", keywords: "viewport scene 场景 视口"),
            panel("documents", keywords: "documents text code script 文档 代码 脚本"),
            panel("media", keywords: "video timeline 视频 时间线"),
            entry("assets.show", "Content Browser", "assets 资源浏览器", command: .showAssets),
            .separator,
            panel("console", keywords: "console log 控制台 日志"),
            panel("terminal", keywords: "terminal shell command line 终端 命令行"),
            entry("problems.show", "Problems", "errors diagnostics 问题诊断错误", command: .showProblems),
            panel("animation", keywords: "animation 动画"),
            panel("render-pipeline", keywords: "render 渲染"),
            panel("developer-tools", keywords: "profiler debugger 开发者工具"),
            .separator,
        ] + contributedPanels + [
            entry("layout.reopen", "Reopen Closed Panel", "reopen 恢复关闭面板", .init(.letter("t"), [.primary, .shift]),
                  command: .reopenClosedPanel),
        ])
    }

    /// Panels packages describe. A panel showing a host view, such as the agent
    /// conversation, has its own entry elsewhere.
    private var contributedPanels: [EditorCommandItem] {
        let panels: [EditorCommandItem] = context.workbench.panels.filter { $0.content == .model && $0.surface == nil && $0.inSurface == nil }.map { panel in
            .entry(EditorCommandEntry(id: "panel." + panel.id, title: panel.title, keywords: "panel 面板",
                                      command: .showPanel(panel.id)))
        }
        return panels.isEmpty ? [] : panels + [.separator]
    }

    private var help: EditorCommandMenu {
        menu("help", "Help", [
            entry("help.documentation", "Documentation", "docs help 文档 帮助", command: .openDocumentation),
        ])
    }

    private func menu(_ id: String, _ title: String, _ items: [EditorCommandItem]) -> EditorCommandMenu {
        EditorCommandMenu(id: id, title: L(title), items: items)
    }

    /// Panel commands reuse the tab title so menus and tabs never disagree.
    private func panelEntry(_ id: String, panel: String, keywords: String, command: EditorCommand) -> EditorCommandItem {
        .entry(EditorCommandEntry(id: id, title: EditorRootViewFactory.localizedPanelTitle(for: panel),
                                  keywords: keywords, command: command))
    }

    private func entry(_ id: String, _ title: String, _ keywords: String = "", _ shortcut: EditorShortcut? = nil,
                       command: EditorCommand, enabled: Bool = true, selected: Bool = false,
                       inPalette: Bool = true) -> EditorCommandItem {
        .entry(EditorCommandEntry(id: id, title: L(title), keywords: keywords, shortcut: shortcut,
                                  command: command, isEnabled: enabled, isSelected: selected,
                                  inPalette: inPalette))
    }
}
