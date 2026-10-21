internal import GuavaUI
internal import GuavaUIRuntime

/// Icon buttons for language commands. Each tooltip names the command and its
/// chord, so the toolbar teaches the shortcut it stands for.
struct ScriptNavigationButtons: View {
    var commands: [ScriptSemanticCommand] = [.back, .forward]
    let canPerform: (ScriptSemanticCommand) -> Bool
    let perform: (ScriptSemanticCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 2) {
            for command in commands {
                AnyView(Button(icon: .resource(command.icon), size: 13, isEnabled: canPerform(command),
                               tooltip: command.help) { perform(command) }
                    .buttonStyle(EditorChromeButtonStyle(height: 24))
                    .accessibility { $0.label = L(command.title) }
                    .debugName("script-navigation-\(command)"))
            }
        }
    }
}

extension ScriptSemanticCommand {
    var icon: BundleImageResource {
        switch self {
        case .back: UIIcons.Navigation.arrowLeft
        case .forward: UIIcons.Navigation.arrowRight
        case .definition: UIIcons.Navigation.arrowUpRight
        case .implementations: UIIcons.Navigation.circleArrowDown
        case .supertypes: UIIcons.Navigation.circleArrowUp
        case .references: UIIcons.Action.search
        case .codeActions: UIIcons.Editor.lightbulb
        case .symbols: UIIcons.Text.list
        case .rename: UIIcons.Action.pencil
        case .signature: UIIcons.Editor.code
        case .format: UIIcons.Action.format
        case .undo: UIIcons.Action.undo
        case .redo: UIIcons.Action.redo
        }
    }
}
