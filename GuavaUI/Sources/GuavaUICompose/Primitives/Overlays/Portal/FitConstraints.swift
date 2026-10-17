internal import Foundation

/// Width constraints are independent of the popup's preferred authored width.
struct PortalFitConstraints: Equatable {
    var minimumWidth: Float = 0
    var viewportMargin: Float = 6

    func widthRange(in window: CGRect) -> (minimum: Float, maximum: Float) {
        let maximum = Float(max(0, window.width - CGFloat(viewportMargin) * 2))
        return (min(maximum, max(0, minimumWidth)), maximum)
    }
}
