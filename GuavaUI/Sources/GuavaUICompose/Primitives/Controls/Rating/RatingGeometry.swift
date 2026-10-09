import Foundation
import GuavaUIRuntime

struct RatingGeometry: Equatable {
    let starSize: Float
    let spacing: Float
    let maximum: Int
    var cellWidth: Float { starSize + 8 }
    var stride: Float { cellWidth + spacing }
    var width: Float { 8 + Float(maximum) * cellWidth + Float(maximum - 1) * spacing }
    var height: Float { max(32, starSize + 8) }
    init(appearance: RatingAppearance, selection: RatingSelection, node: Node) {
        let density = appearance.size ?? node.compositionValue(of: ControlSizeEnvironment.key)
        starSize = appearance.starSize ?? (density == .mini ? 12 : density == .small ? 16 : density == .large ? 28 : 20)
        spacing = appearance.spacing; maximum = selection.maximum
    }
    func starRect(_ index: Int, origin: CGPoint, height: Float) -> UIRect {
        UIRect(x: Float(origin.x) + 8 + Float(index) * stride,
            y: Float(origin.y) + (height - starSize) / 2, width: starSize, height: starSize)
    }
    func candidate(at eventX: Float, node: Node, precision: RatingPrecision) -> Double {
        guard eventX.isFinite else { return 0 }
        let x = max(0, min(width, eventX - Float(node.absoluteOrigin.x) - 4))
        let index = min(maximum - 1, Int(x / stride))
        let fraction = (x - Float(index) * stride - 4) / starSize
        let part = precision == .half && fraction <= 0.5 ? 0.5 : 1.0
        return Double(index) + part
    }
    func contains(_ x: Float, _ y: Float, node: Node) -> Bool {
        let origin = node.absoluteOrigin
        return CGRect(x: origin.x, y: origin.y, width: min(CGFloat(width), node.frame.width), height: node.frame.height)
            .contains(CGPoint(x: CGFloat(x), y: CGFloat(y)))
    }
}

final class RatingSession: NodeResource {
    var binding: Binding<Double> = .constant(0)
    var preview: Double?
    var pressedCandidate: Double?
    var hasMoved = false
    var configuration: Configuration?
    private weak var capture: PointerCapture?
    private weak var focus: FocusChain?
    struct Configuration: Equatable {
        let value: Double
        let selection: RatingSelection
        let geometry: RatingGeometry
    }
    func mount(node: Node) { capture = PointerCaptureHolder.current; focus = FocusChainHolder.current }
    func unmount(node: Node) { cancel(node: node); if focus?.focused === node { focus?.clear() } }
    func cancel(node: Node) {
        preview = nil; pressedCandidate = nil; hasMoved = false
        if capture?.target === node { capture?.release() }
        node.markRenderDirty(reason: .styleSet(field: "ratingInteraction"))
    }
    func begin(_ candidate: Double, node: Node) {
        preview = candidate; pressedCandidate = candidate; hasMoved = false
        capture?.acquire(node)
        node.markRenderDirty(reason: .styleSet(field: "ratingInteraction"))
    }
    func hover(_ candidate: Double?, node: Node) {
        if pressedCandidate != nil, preview != candidate { hasMoved = true }
        guard preview != candidate else { return }
        preview = candidate; node.markRenderDirty(reason: .styleSet(field: "ratingInteraction"))
    }
}
