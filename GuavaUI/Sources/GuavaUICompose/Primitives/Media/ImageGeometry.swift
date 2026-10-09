import GuavaUIRuntime

/// Central aspect cropping keeps rounded masks on the container boundary.
struct ImageGeometry {
    let rect: UIRect
    var uvMin: (x: Float, y: Float) = (0, 0)
    var uvMax: (x: Float, y: Float) = (1, 1)

    init(container: UIRect, source: (width: Float, height: Float)?, mode: Image.ContentMode) {
        guard let source, source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0, container.width > 0, container.height > 0,
              mode != .stretch else { rect = container; return }
        let sourceAspect = source.width / source.height
        let aspect = container.width / container.height
        if mode == .fill {
            rect = container
            if sourceAspect > aspect {
                let span = aspect / sourceAspect
                uvMin.x = (1 - span) / 2; uvMax.x = (1 + span) / 2
            } else {
                let span = sourceAspect / aspect
                uvMin.y = (1 - span) / 2; uvMax.y = (1 + span) / 2
            }
        } else {
            let width = sourceAspect >= aspect ? container.width : container.height * sourceAspect
            let height = sourceAspect >= aspect ? container.width / sourceAspect : container.height
            rect = UIRect(x: container.x + (container.width - width) / 2,
                          y: container.y + (container.height - height) / 2, width: width, height: height)
        }
    }
}
