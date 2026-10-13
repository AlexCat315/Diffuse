import GuavaUI
import GuavaUIRuntime
import CounterExample

/// Adapts the portable counter's custom text primitives to the native font service.
public struct CounterContent: View {
    private let counter: CounterView
    public init(counter: CounterView = CounterView()) { self.counter = counter }

    public var body: some View {
        counter.compositionLocal(CounterText.painter, { text, list, origin in
            guard let environment = TextEnvironmentHolder.current else { return }
            let layout = environment.cachedLayout(text: text.text, font: .system(size: text.size), lineHeight: text.size * 1.3)
            list.addText(layout, origin: (Float(origin.x) + text.inset, Float(origin.y)), color: text.color,
                         textureID: environment.atlasTextureID, atlas: environment.atlas)
        })
    }
}
