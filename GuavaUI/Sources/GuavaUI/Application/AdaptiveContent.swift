import GuavaUICompose
import GuavaUIRuntime

struct AdaptiveApplicationContent<Root: View>: View {
    let content: Root
    @State var environment: UIEnvironment

    init(content: Root, environment: State<UIEnvironment>) {
        self.content = content
        self._environment = environment
    }
    var body: some View {
        Box { content }
            .padding(EdgeInsets(top: environment.safeArea.top, leading: environment.safeArea.leading,
                                bottom: environment.safeArea.bottom, trailing: environment.safeArea.trailing))
            .flex(1, shrink: 1, basis: 0)
            .frame(minWidth: 0, minHeight: 0)
            .surfaceEnvironment(environment)
            .reducedMotion(environment.reducesMotion)
    }
}
