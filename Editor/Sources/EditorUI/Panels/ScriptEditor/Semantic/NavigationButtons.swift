internal import GuavaUI
internal import GuavaUIRuntime

struct ScriptNavigationButtons: View {
    let canPerform: (ScriptSemanticCommand) -> Bool
    let perform: (ScriptSemanticCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 2) {
            navigationButton(.back, icon: UIIcons.Navigation.arrowLeft, shortcut: "Option/Alt+Left", name: "back")
            navigationButton(.definition, icon: UIIcons.Navigation.arrowUpRight, shortcut: "F12", name: "definition")
            navigationButton(.references, icon: UIIcons.Editor.gitBranch, shortcut: "Shift+F12", name: "references")
        }
    }

    private func navigationButton(_ command: ScriptSemanticCommand, icon: BundleImageResource,
                                  shortcut: String, name: String) -> some View {
        Button(icon: .resource(icon), size: 12, isEnabled: canPerform(command),
               tooltip: "\(L(command.title)) (\(shortcut))") { perform(command) }
            .buttonStyle(ToggleButtonStyle(minWidth: 24, height: 24))
            .accessibility { $0.label = L(command.title) }
            .debugName("script-navigation-\(name)")
    }
}
