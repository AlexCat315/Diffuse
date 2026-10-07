import EditorCore
import Foundation

struct EditorPaletteCommand {
    let id: String
    let title: String
    let shortcut: String
    let keywords: String
    let command: EditorMenuCommand
    var enabled: Bool = true
}

enum EditorCommandSearch {
    static var primaryKey: String {
        #if os(macOS)
        "⌘"
        #else
        "Ctrl+"
        #endif
    }

    static func commands(app: EditorApplication) -> [EditorPaletteCommand] {
        let state = app.store.state
        let canEdit = state.timing.playbackState == .stopped
        let canSelect = canEdit && !state.selection.selectedEntityIDs.isEmpty
        func entry(_ id: String, _ title: String, _ key: String = "", _ keywords: String = "",
                   _ command: EditorMenuCommand, enabled: Bool = true) -> EditorPaletteCommand {
            .init(id: id, title: L(title), shortcut: key.isEmpty ? "" : primaryKey + key,
                  keywords: keywords, command: command, enabled: enabled)
        }
        var commands = [
            entry("scene.save", "Save Scene", "S", "save 保存场景", .saveScene),
            entry("scene.open", "Open Scene", "O", "open 打开场景", .openScene),
            entry("scene.new", "New Scene", "N", "new 新建", .newScene),
            entry("scene.settings", "Scene Settings", "", "physics scene 场景物理设置", .showSceneSettings),
            entry("edit.undo", "Undo", "Z", "撤销", .undo, enabled: canEdit && app.canUndo),
            entry("edit.redo", "Redo", "Shift+Z", "重做", .redo, enabled: canEdit && app.canRedo),
            entry("edit.duplicate", "Duplicate Selection", "D", "duplicate 复制", .duplicateSelection, enabled: canSelect),
            entry("edit.delete", "Delete Selection", "", "delete 删除", .deleteSelection, enabled: canSelect),
            entry("assets.import", "Import Assets", "", "import 导入资源", .importAssets, enabled: canEdit),
            entry("assets.show", "Content Browser", "", "assets 资源浏览器", .showAssets),
            entry("scripts.show", "Scripts", "5", "code script 编程脚本", .showScripts),
            entry("problems.show", "Problems", "", "errors diagnostics 问题诊断错误", .showProblems),
            entry("project.build", "Build Project", "B", "export build 导出构建", .buildProject, enabled: state.workspace.mode.isGameWorkspace),
            entry("project.run", "Build and Run", "R", "export run 构建运行", .buildAndRun, enabled: state.workspace.mode.isGameWorkspace),
            entry("layout.save", "Save Layout", "", "layout workspace 保存布局", .saveLayout),
            entry("layout.reset", "Reset Layout", "0", "layout workspace 重置布局", .resetLayout),
            entry("layout.restore", "Restore Panels", "", "maximize restore 恢复面板", .restorePanels),
            entry("layout.viewport", "Maximize Viewport", "", "maximize 最大化视口", .maximizePanel("viewport")),
            entry("layout.scripts", "Maximize Scripts", "", "maximize 最大化脚本", .maximizePanel("scripts")),
            entry("layout.reopen", "Reopen Closed Panel", "Shift+T", "reopen 恢复关闭面板", .reopenClosedPanel),
            entry("preferences", "Settings", ",", "preferences 设置", .openSettings),
            entry("theme.toggle", "Toggle Theme", "", "dark light 主题", .toggleTheme)
        ]
        for (mode, key) in [(EditorWorkspaceMode.level, "1"), (.scripting, "4"), (.modeling, "2"), (.animation, "3")] {
            commands.append(entry("workspace." + mode.rawValue, mode.title, key, "workspace 工作空间",
                                  .setWorkspaceMode(mode)))
        }
        for (playback, title) in [(PlaybackState.playing, "Play"), (.paused, "Pause"), (.stopped, "Stop")] {
            commands.append(entry("playback." + playback.rawValue, title, "", "game preview 游戏试玩",
                .setPlaybackState(playback),
                enabled: state.workspace.mode.isGameWorkspace && state.timing.playbackState.canTransition(to: playback)))
        }
        for preset in EditorLayoutPreset.presets(for: state.workspace.mode) {
            commands.append(entry("layout." + preset.rawValue, preset.title, "", "layout 布局",
                                  .setLayoutPreset(preset)))
        }
        for mode in EditorInteractionMode.allCases {
            commands.append(entry("interaction." + mode.rawValue, mode.title, "", "agent manual AI 交互方式 手动 智能体",
                                  .setInteractionMode(mode)))
        }
        return commands.filter { EditorWorkspaceCommandPolicy.allows($0.command, in: state.workspace.mode) }
    }

    /// Exact and word matches precede subsequence matches. Multi-word queries
    /// must match every token, including localized labels, IDs and paths.
    static func score(_ query: String, in text: String) -> Int? {
        let haystack = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
        var total = 0
        for token in tokens {
            if haystack == token { total += 100 }
            else if haystack.contains(token) { total += 60 }
            else {
                var cursor = haystack.startIndex
                for character in token {
                    guard let found = haystack[cursor...].firstIndex(of: character) else { return nil }
                    cursor = haystack.index(after: found)
                }
                total += 10
            }
        }
        return total
    }
}
