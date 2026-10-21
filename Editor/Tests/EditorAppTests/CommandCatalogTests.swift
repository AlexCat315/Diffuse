@testable import EditorUI
import EditorCore
import EngineKernel
import GuavaUICompose
import Testing

@Suite("EditorCommandCatalog")
struct CommandCatalogTests {
    @Test("Space and Layout submenus belong to View and layouts belong to the active workspace")
    func menuOrganization() throws {
        for mode in [EditorWorkspaceMode.level, .modeling, .animation, .scripting] {
            let preset = EditorLayoutPreset.default(for: mode)
            let catalog = make(workspace: mode, preset: preset)
            let view = try #require(catalog.menus.first { $0.id == "view" })
            let space = try #require(submenu("space", in: view))
            let layout = try #require(submenu("layout", in: view))
            let spaceEntries = entries(space.items)
            #expect(spaceEntries.compactMap(\.shortcut?.key.equivalent) == ["1", "2", "3", "4", "5"])
            #expect(spaceEntries.filter(\.isSelected).count == 1)
            let presets = entries(layout.items).compactMap { entry -> EditorLayoutPreset? in
                if case let .setLayoutPreset(preset) = entry.command { return preset }
                return nil
            }
            #expect(presets == EditorLayoutPreset.presets(for: mode))
            #expect(entries(layout.items).filter(\.isSelected).count == 1)
            let window = try #require(catalog.menus.first { $0.id == "window" })
            for entry in entries(window.items) {
                switch entry.command {
                case .setWorkspaceMode, .setLayoutPreset: Issue.record("Window mixes workspace and panel commands")
                default: break
                }
            }
        }
    }

    @Test("film workspaces omit game playback and builds instead of showing dead commands")
    func filmTransport() {
        for mode in [EditorWorkspaceMode.modeling, .animation] {
            let catalog = make(workspace: mode)
            #expect(!catalog.menus.contains { $0.id == "run" })
            for entry in catalog.entries {
                switch entry.command {
                case .setPlaybackState, .togglePlayback, .buildProject, .buildAndRun:
                    Issue.record("\(mode) exposes \(entry.id)")
                default: break
                }
            }
        }
    }

    @Test("text workspaces hide scene-only panels and asset commands")
    func documentsScope() {
        let ids = Set(make(workspace: .documents).entries.map(\.id))
        #expect(!ids.contains("scene.settings"))
        #expect(!ids.contains("assets.import"))
        #expect(!ids.contains("assets.show"))
        #expect(ids.contains("panel.documents"))
        #expect(ids.contains("panel.files"))
        #expect(ids.contains("agent.show"))
        // ⌘S saves the open file here; scene, selection and world commands are absent.
        for absent in ["scene.save", "scene.new", "scene.open", "edit.duplicate", "edit.delete", "select.all", "world.frame"] {
            #expect(!ids.contains(absent), "\(absent) leaked into the Write Space")
        }
        let catalog = EditorCommandCatalog.make(EditorCommandContext(workspaceMode: .documents,
                                                                     document: EditorCommandDocument(isDirty: true)))
        let save = catalog.entries.first { $0.id == "document.save" }
        #expect(save?.shortcut?.key.equivalent == "s")
        #expect(save?.isEnabled == true)
        #expect(catalog.entries.first { $0.id == "document.close" }?.isEnabled == false)
        #expect(!catalog.menus.contains { $0.id == "select" || $0.id == "world" })
        let clean = EditorCommandCatalog.make(EditorCommandContext(workspaceMode: .documents,
                                                                   document: EditorCommandDocument(isDirty: false)))
        #expect(clean.entries.first { $0.id == "document.save" }?.isEnabled == false)
        #expect(clean.entries.first { $0.id == "document.close" }?.isEnabled == true)
    }

    @Test("scene Spaces expose Select and World menus backed by scene commands")
    func selectAndWorld() throws {
        let catalog = full()
        let ids = Set(catalog.entries.map(\.id))
        for id in ["select.all", "select.none", "select.invert", "select.descendants", "world.frame", "world.visibility",
                   "world.lock", "world.add.cube", "world.add.camera"] {
            #expect(ids.contains(id), "missing \(id)")
        }
        // Text fields own ⌘A; Select All must not claim it from the native menu.
        #expect(catalog.entries.first { $0.id == "select.all" }?.shortcut == nil)
        #expect(!ids.contains("document.save"))
        #expect(catalog.menus.map(\.id) == ["file", "edit", "select", "world", "view", "agent", "run", "window", "help"])
    }

    @Test("exposes the core file / edit / build commands")
    func coreCommands() {
        let ids = Set(full().entries.map(\.id))
        for id in ["project.close", "scene.new", "scene.open", "scene.save", "assets.import", "edit.undo", "edit.redo",
                   "edit.duplicate", "edit.delete", "project.build", "project.run", "layout.reopen",
                   "agent.intent", "search.resources", "palette.commands", "playback.toggle", "preferences", "app.about"] {
            #expect(ids.contains(id), "missing \(id)")
        }
    }

    @Test("edit commands reflect actual history and selection availability")
    func editCommandAvailability() {
        for entry in make().entries where ["edit.undo", "edit.redo", "edit.duplicate", "edit.delete"].contains(entry.id) {
            #expect(!entry.isEnabled)
        }
        for entry in full().entries where ["edit.undo", "edit.redo", "edit.duplicate", "edit.delete"].contains(entry.id) {
            #expect(entry.isEnabled)
        }
    }

    @Test("scene authoring commands are disabled while playing or paused")
    func playbackDisablesSceneAuthoringCommands() {
        for playbackState in [PlaybackState.playing, .paused] {
            let catalog = EditorCommandCatalog.make(EditorCommandContext(workspaceMode: .level, playbackState: playbackState,
                                                                         canUndo: true, canRedo: true, hasSelection: true))
            for entry in catalog.entries {
                switch entry.command {
                case .newScene, .openScene, .undo, .redo, .duplicateSelection, .deleteSelection, .importAssets:
                    #expect(!entry.isEnabled)
                default:
                    break
                }
            }
        }
        #expect(EditorSceneAuthoringPolicy.canEditScene(during: .stopped))
        #expect(!EditorSceneAuthoringPolicy.canEditScene(during: .playing))
        #expect(!EditorSceneAuthoringPolicy.canEditScene(during: .paused))
    }

    @Test("playback state selects exactly the matching transport command")
    func playbackSelection() {
        for entry in make(.playing).entries {
            switch entry.command {
            case .setPlaybackState(.playing):
                #expect(entry.isSelected)
                #expect(!entry.isEnabled)
            case .setPlaybackState(.paused), .setPlaybackState(.stopped):
                #expect(!entry.isSelected)
                #expect(entry.isEnabled)
            default: break
            }
        }
    }

    @Test("playback policy rejects no-op and stopped-to-paused transitions; toggle plays or pauses")
    func playbackTransitionPolicy() {
        #expect(EditorPlaybackCommandPolicy.canTransition(from: .stopped, to: .playing))
        #expect(!EditorPlaybackCommandPolicy.canTransition(from: .stopped, to: .paused))
        #expect(!EditorPlaybackCommandPolicy.canTransition(from: .stopped, to: .stopped))
        #expect(EditorPlaybackCommandPolicy.canTransition(from: .playing, to: .paused))
        #expect(EditorPlaybackCommandPolicy.canTransition(from: .playing, to: .stopped))
        #expect(!EditorPlaybackCommandPolicy.canTransition(from: .playing, to: .playing))
        #expect(EditorPlaybackCommandPolicy.canTransition(from: .paused, to: .playing))
        #expect(EditorPlaybackCommandPolicy.canTransition(from: .paused, to: .stopped))
        #expect(!EditorPlaybackCommandPolicy.canTransition(from: .paused, to: .paused))
        #expect(EditorPlaybackCommandPolicy.toggleTarget(from: .stopped) == .playing)
        #expect(EditorPlaybackCommandPolicy.toggleTarget(from: .playing) == .paused)
        #expect(EditorPlaybackCommandPolicy.toggleTarget(from: .paused) == .playing)
    }

    @Test("stopped transport disables pause and the already-active stop command")
    func stoppedPlaybackMenuAvailability() {
        for entry in make(.stopped).entries {
            switch entry.command {
            case .setPlaybackState(.playing): #expect(entry.isEnabled)
            case .setPlaybackState(.paused), .setPlaybackState(.stopped): #expect(!entry.isEnabled)
            default: break
            }
        }
    }

    @Test("active workspace mode is marked selected")
    func workspaceSelection() {
        let entries = make(workspace: .modeling).entries
        #expect(entries.first { $0.id == "workspace.modeling" }?.isSelected == true)
        #expect(entries.first { $0.id == "workspace.level" }?.isSelected == false)
    }

    @Test("undo binds to primary+Z and delete to an unmodified Delete key")
    func editShortcuts() {
        let entries = full().entries
        let undo = entries.first { $0.id == "edit.undo" }
        #expect(undo?.shortcut?.key.equivalent == "z")
        // `.primary` is Cmd on macOS and Ctrl elsewhere.
        #expect(undo?.shortcut?.modifiers.contains(.primary) == true)
        let deletion = entries.first { $0.id == "edit.delete" }
        #expect(deletion?.shortcut?.key.equivalent == "\u{8}")
        #expect(deletion?.shortcut?.modifiers.isEmpty == true)
        #expect(deletion?.isEnabled == true)
    }

    @Test("ids and key chords are unique across the whole tree")
    func uniqueness() {
        for mode in [EditorWorkspaceMode.documents, .video, .level, .scripting, .modeling, .animation] {
            let entries = make(workspace: mode).entries
            let ids = entries.map(\.id)
            #expect(Set(ids).count == ids.count, "duplicate ids in \(mode)")
            let chords = entries.compactMap(\.shortcut).map { "\($0.key.equivalent)-\($0.modifiers.rawValue)" }
            #expect(Set(chords).count == chords.count, "duplicate chords in \(mode)")
        }
    }

    @Test("menus never start, end or double up on separators, and never show empty submenus")
    func structureHygiene() {
        func check(_ items: [EditorCommandItem], path: String) {
            #expect(!items.isEmpty, "\(path) is empty")
            if case .separator = items.first { Issue.record("\(path) starts with a separator") }
            if case .separator = items.last { Issue.record("\(path) ends with a separator") }
            for (index, item) in items.enumerated() {
                if case .separator = item, index > 0, case .separator = items[index - 1] {
                    Issue.record("\(path) repeats a separator")
                }
                if case let .submenu(menu) = item { check(menu.items, path: path + "/" + menu.id) }
            }
        }
        for mode in [EditorWorkspaceMode.documents, .video, .level, .scripting, .modeling, .animation] {
            for playback in [PlaybackState.stopped, .playing, .paused] {
                for menu in make(playback, workspace: mode).menusWithApplicationItems {
                    check(menu.items, path: "\(mode)/\(menu.id)")
                }
            }
        }
    }

    @Test("without an application menu, Settings joins Edit and About joins Help")
    func applicationItemPlacement() throws {
        let catalog = full()
        #expect(!catalog.menus.flatMap { entries($0.items) }.contains { $0.id == "preferences" || $0.id == "app.about" })
        let menus = catalog.menusWithApplicationItems
        let edit = try #require(menus.first { $0.id == "edit" })
        let help = try #require(menus.first { $0.id == "help" })
        #expect(entries(edit.items).last?.id == "preferences")
        #expect(entries(help.items).last?.id == "app.about")
        #expect(catalog.entries.filter { $0.id == "preferences" }.count == 1)
    }

    @Test("palette search lists catalog entries except the palette openers")
    func paletteEntries() {
        let palette = full().entries.filter(\.inPalette).map(\.id)
        #expect(!palette.contains("agent.intent"))
        #expect(!palette.contains("palette.commands"))
        #expect(!palette.contains("search.resources"))
        #expect(palette.contains("scene.save"))
        #expect(palette.contains("layout.levelDefault"))
    }

    @Test("shortcut labels follow the platform convention")
    func shortcutLabels() {
        let redo = EditorShortcut(.letter("z"), [.primary, .shift])
        #if os(macOS)
        #expect(redo.label == "⇧⌘Z")
        #expect(EditorShortcut(.delete, []).label == "⌫")
        #else
        #expect(redo.label == "Ctrl+Shift+Z")
        #expect(EditorShortcut(.delete, []).label == "Delete")
        #endif
    }

    @Test("every chord resolves its physical key")
    func keyMatching() {
        let catalog = full()
        func key(_ scancode: UInt32, _ modifiers: KeyModifiers) -> KeyEvent {
            KeyEvent(scancode: scancode, keycode: 0, modifiers: modifiers, isRepeat: false)
        }
        #expect(catalog.entry(matching: key(Scancode.s, [.lgui]))?.id == "scene.save")
        #expect(catalog.entry(matching: key(Scancode.s, [.rctrl]))?.id == "scene.save")
        #expect(catalog.entry(matching: key(Scancode.z, [.lgui]))?.id == "edit.undo")
        #expect(catalog.entry(matching: key(Scancode.z, [.lgui, .rshift]))?.id == "edit.redo")
        #expect(catalog.entry(matching: key(Scancode.p, [.lgui]))?.id == "search.resources")
        #expect(catalog.entry(matching: key(Scancode.p, [.lgui, .lshift]))?.id == "palette.commands")
        #expect(catalog.entry(matching: key(Scancode.digit3, [.lgui]))?.id == "workspace.animation")
        #expect(catalog.entry(matching: key(Scancode.digit0, [.lgui]))?.id == "layout.reset")
        #expect(catalog.entry(matching: key(Scancode.keypadEnter, [.lgui]))?.id == "playback.toggle")
        #expect(catalog.entry(matching: key(Scancode.delete, []))?.id == "edit.delete")
        #expect(catalog.entry(matching: key(Scancode.backspace, []))?.id == "edit.delete")
        // An unmodified letter or a chord with an extra Option never fires a command.
        #expect(catalog.entry(matching: key(Scancode.s, [])) == nil)
        #expect(catalog.entry(matching: key(Scancode.s, [.lgui, .lalt])) == nil)
    }

    @Test("View → Panels toggles each docked edge in every Space")
    func panelAreas() throws {
        for mode in [EditorWorkspaceMode.documents, .video, .level, .scripting, .modeling, .animation] {
            let view = try #require(make(workspace: mode).menus.first { $0.id == "view" })
            let panels = try #require(submenu("panels", in: view))
            let areas = entries(panels.items).compactMap { entry -> EditorPanelArea? in
                if case let .togglePanelArea(area) = entry.command { return area }
                return nil
            }
            #expect(areas == [.leading, .trailing, .bottom])
        }
        let bottom = try #require(full().entries.first { $0.id == "area.bottom" })
        #expect(bottom.shortcut == EditorShortcut(.letter("j")))
    }

    @Test("Stop has its own chord and is only available while the game runs")
    func stopShortcut() throws {
        let stop = try #require(make(.playing).entries.first { $0.id == "playback.stopped" })
        #expect(stop.shortcut == EditorShortcut(.enter, [.primary, .shift]))
        #expect(stop.isEnabled)
        #expect(make().entries.first { $0.id == "playback.stopped" }?.isEnabled == false)
    }

    @Test("Only chords refused because the game runs are reported as blocked by playback")
    func blockedOnlyByPlayback() throws {
        let playing = EditorCommandContext(workspaceMode: .level, playbackState: .playing, hasSelection: true)
        let catalog = EditorCommandCatalog.make(playing)
        let duplicate = try #require(catalog.entries.first { $0.id == "edit.duplicate" })
        #expect(EditorCommandCatalog.isBlockedOnlyByPlayback(duplicate, in: playing))
        // Bare Delete belongs to the game while it runs.
        let delete = try #require(catalog.entries.first { $0.id == "edit.delete" })
        #expect(!EditorCommandCatalog.isBlockedOnlyByPlayback(delete, in: playing))
        // Nothing selected: playback is not the only reason.
        let empty = EditorCommandContext(workspaceMode: .level, playbackState: .playing)
        let noSelection = try #require(EditorCommandCatalog.make(empty).entries.first { $0.id == "edit.duplicate" })
        #expect(!EditorCommandCatalog.isBlockedOnlyByPlayback(noSelection, in: empty))
        let stopped = EditorCommandContext(workspaceMode: .level, hasSelection: true)
        let enabled = try #require(EditorCommandCatalog.make(stopped).entries.first { $0.id == "edit.duplicate" })
        #expect(!EditorCommandCatalog.isBlockedOnlyByPlayback(enabled, in: stopped))
    }

    private func entries(_ items: [EditorCommandItem]) -> [EditorCommandEntry] {
        items.flatMap { item -> [EditorCommandEntry] in
            switch item {
            case let .entry(entry): [entry]
            case let .submenu(menu): entries(menu.items)
            case .separator: []
            }
        }
    }

    private func submenu(_ id: String, in menu: EditorCommandMenu) -> EditorCommandMenu? {
        for item in menu.items {
            if case let .submenu(nested) = item, nested.id == id { return nested }
        }
        return nil
    }

    private func make(_ playback: PlaybackState = .stopped,
                      workspace: EditorWorkspaceMode = .level,
                      preset: EditorLayoutPreset? = nil) -> EditorCommandCatalog {
        .make(EditorCommandContext(workspaceMode: workspace, layoutPreset: preset, playbackState: playback))
    }

    private func full() -> EditorCommandCatalog {
        .make(EditorCommandContext(workspaceMode: .level, canUndo: true, canRedo: true, hasSelection: true))
    }
}
