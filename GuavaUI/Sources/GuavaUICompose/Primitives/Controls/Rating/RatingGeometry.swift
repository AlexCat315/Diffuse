import Foundation
import GuavaUIRuntime

struct RatingGeometry: Equatable {
    let starSize: Float
    let spacing: Float
    let maximum: Int
    let cellWidth: Float
    var stride: Float { cellWidth + spacing }
    var width: Float { 8 + Float(maximum) * cellWidth + Float(maximum - 1) * spacing }
    var height: Float { max(32, cellWidth) }
    init(appearance: RatingAppearance, selection: RatingSelection, node: Node) {
        let density = appearance.size ?? node.compositionValue(of: ControlSizeEnvironment.key)
        starSize = appearance.starSize ?? (density == .mini ? 12 : density == .small ? 16 : density == .large ? 28 : 20)
        let surface = node.compositionValue(of: SurfaceEnvironment.key)
        cellWidth = max(starSize + 8, selection.isInteractive && surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
        spacing = appearance.spacing; maximum = selection.maximum
    }
    /// Direction can be applied after the primitive's update pass, so draw and
    /// input resolve it lazily instead of snapshoting a stale value.
    func isRTL(_ node: Node) -> Bool { node.resolvesRightToLeft }
    func starRect(_ index: Int, origin: CGPoint, height: Float, rtl: Bool) -> UIRect {
        let visualIndex = rtl ? maximum - 1 - index : index
        return UIRect(x: Float(origin.x) + 4 + (cellWidth - starSize) / 2 + Float(visualIndex) * stride,
            y: Float(origin.y) + (height - starSize) / 2, width: starSize, height: starSize)
    }
    func candidate(at eventX: Float, node: Node, precision: RatingPrecision) -> Double {
        guard eventX.isFinite else { return 0 }
        let rtl = isRTL(node)
        let x = max(0, min(width, eventX - Float(node.absoluteOrigin.x) - 4))
        let visualIndex = min(maximum - 1, Int(x / stride))
        let fraction = max(0, min(1, (x - Float(visualIndex) * stride - (cellWidth - starSize) / 2) / starSize))
        let index = rtl ? maximum - 1 - visualIndex : visualIndex
        return Double(index) + precision.part(rtl ? 1 - fraction : fraction)
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
