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
            .surfaceEnvironment(environment)
            .reducedMotion(environment.reducesMotion)
    }
}
