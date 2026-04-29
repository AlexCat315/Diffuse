import EditorCore
import GuavaUICompose
import GuavaUIRuntime

extension View {
    func toggleButtonStyle(_ isActive: Bool) -> some View {
        compositionLocal(ButtonStyleEnvironment.key,
                         isActive ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(GhostButtonStyle()))
    }
}
