internal import Foundation

/// Width constraints are independent of the popup's preferred authored width.
struct PortalFitConstraints: Equatable {
    var minimumWidth: Float = 0
    var viewportMargin: Float = 6
    var maximumWidth: Float?
    var maximumHeight: Float?

    func widthRange(in window: CGRect) -> (minimum: Float, maximum: Float) {
        let available = Float(max(0, window.width - CGFloat(viewportMargin) * 2))
        let maximum = maximumWidth.map { min(available, max(0, $0)) } ?? available
        return (min(maximum, max(0, minimumWidth)), maximum)
    }
    func heightLimit(in window: CGRect) -> Float {
        let available = Float(max(0, window.height - CGFloat(viewportMargin) * 2))
        return maximumHeight.map { min(available, max(0, $0)) } ?? available
    }
}
