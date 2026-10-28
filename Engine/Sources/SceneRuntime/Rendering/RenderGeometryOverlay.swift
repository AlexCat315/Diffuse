import SIMDCompat

/// Transient editor geometry. Positions are in world space; widths and marker
/// sizes use logical viewport pixels. Never part of an authored scene asset.
public struct RenderGeometryOverlay: Sendable, Equatable {
    public struct Triangle: Sendable, Equatable {
        public var a, b, c: SIMD3<Float>
        public var color: SIMD4<Float>
        /// Opposite-vertex edges (BC, CA, AB); zero widths suppress GPU-only diagonals.
        public var edgeWidths: SIMD3<Float>
        public var edgeA, edgeB, edgeC: SIMD4<Float>
        public init(_ a: SIMD3<Float>,_ b: SIMD3<Float>,_ c: SIMD3<Float>,color: SIMD4<Float>,
                    edgeWidths: SIMD3<Float> = .zero,edgeA: SIMD4<Float> = .zero,
                    edgeB: SIMD4<Float> = .zero,edgeC: SIMD4<Float> = .zero) {
            self.a = a; self.b = b; self.c = c; self.color = color
            self.edgeWidths = edgeWidths; self.edgeA = edgeA; self.edgeB = edgeB; self.edgeC = edgeC
        }
    }
    public struct Line: Sendable, Equatable {
        public var a, b: SIMD3<Float>
        public var color: SIMD4<Float>
        public var width: Float
        public init(_ a: SIMD3<Float>,_ b: SIMD3<Float>,color: SIMD4<Float>,width: Float = 1) {
            self.a = a; self.b = b; self.color = color; self.width = width
        }
    }
    public struct Point: Sendable, Equatable {
        public var position: SIMD3<Float>
        public var color: SIMD4<Float>
        public var size: Float
        public init(_ position: SIMD3<Float>,color: SIMD4<Float>,size: Float = 5) {
            self.position = position; self.color = color; self.size = size
        }
    }
    public var triangles: [Triangle] = []
    public var lines: [Line] = []
    public var points: [Point] = []
    public var xray: Bool
    public var viewportSize: SIMD2<Float>
    public var isEmpty: Bool { triangles.isEmpty && lines.isEmpty && points.isEmpty }

    public init(viewportSize: SIMD2<Float>,xray: Bool = false) {
        self.viewportSize = viewportSize; self.xray = xray
    }
}
