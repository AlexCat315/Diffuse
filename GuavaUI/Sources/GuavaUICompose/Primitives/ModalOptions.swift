import GuavaUIRuntime

public enum ModalPlacement: Sendable { case center, leading, trailing, top, bottom }
public struct ModalGeometry {
    public var width: Float = 760
    public var height: Float = 560
    public var inset: Float = 16
    public var cornerRadius: Float = 8
    public var placement: ModalPlacement = .center
    public init() {}
    mutating func validate() {
        width = width.isFinite ? max(64, width) : 760; height = height.isFinite ? max(64, height) : 560
        inset = inset.isFinite ? max(0, inset) : 16; cornerRadius = cornerRadius.isFinite ? max(0, cornerRadius) : 8
    }
    func transition(size: CGSize) -> Transition {
        switch placement {
        case .center: .opacity.combined(with: .move(edge: .bottom, distance: 12))
        case .leading: .move(edge: .leading, distance: Float(size.width))
        case .trailing: .move(edge: .trailing, distance: Float(size.width))
        case .top: .move(edge: .top, distance: Float(size.height))
        case .bottom: .move(edge: .bottom, distance: Float(size.height))
        }
    }
}
public struct ModalDismissal {
    public var closesOnBackdrop = true
    public var closesOnEscape = true
    public init() {}
}
public struct ModalOptions {
    public var geometry = ModalGeometry()
    public var dismissal = ModalDismissal()
    public init() {}
}
