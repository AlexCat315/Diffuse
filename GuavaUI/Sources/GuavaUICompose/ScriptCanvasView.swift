import EngineKernel
import GuavaUIRuntime

final class ScriptCanvasModel: _ObservableObject {
    private let publisher = _ObservablePublisher<ScriptCanvasModel>()
    private(set) var canvas = InGameCanvas()

    func update(_ canvas: InGameCanvas) {
        guard self.canvas != canvas else { return }
        self.canvas = canvas
        publisher.send()
    }
    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable {
        publisher.register(on: self, handler: handler)
    }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

struct ScriptCanvasView: View {
    private var _canvas: Observed<ScriptCanvasModel, InGameCanvas>
    init(model: ScriptCanvasModel) { _canvas = Observed(\.canvas, on: model) }

    var body: some View {
        Box {
            for command in _canvas.wrappedValue.commands {
                draw(command)
            }
        }.flex()
    }

    private func draw(_ command: InGameCanvasCommand) -> AnyView {
        switch command {
        case let .label(text, x, y, size, color):
            guard x.isFinite, y.isFinite, size.isFinite else { return AnyView(EmptyView()) }
            return AnyView(Text(text).font(Font.system(size: max(1, size)))
                .foregroundColor(convert(color)).absolutePosition(left: x, top: y))
        case let .rect(x, y, w, h, color, radius):
            guard validRect(x, y, w, h) else { return AnyView(EmptyView()) }
            return AnyView(Box {}.frame(width: max(0, w), height: max(0, h))
                .background(convert(color)).cornerRadius(radius.isFinite ? max(0, radius) : 0)
                .absolutePosition(left: x, top: y))
        case let .progressBar(x, y, w, h, value, maximum, fill, background, radius):
            guard validRect(x, y, w, h) else { return AnyView(EmptyView()) }
            let fraction = value.isFinite && maximum.isFinite && maximum > 0 ? max(0, min(1, value / maximum)) : 0
            let corner = radius.isFinite ? max(0, radius) : 0
            return AnyView(Box {
                Box {}.frame(width: w * fraction, height: h).background(convert(fill)).cornerRadius(corner)
                    .absolutePosition(left: 0, top: 0)
            }.frame(width: w, height: h).background(convert(background)).cornerRadius(corner)
                .absolutePosition(left: x, top: y))
        }
    }

    private func validRect(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> Bool {
        x.isFinite && y.isFinite && w.isFinite && h.isFinite && w >= 0 && h >= 0
    }
    private func convert(_ color: InGameUIColor) -> Color {
        Color(r: color.r, g: color.g, b: color.b, a: color.a)
    }
}
