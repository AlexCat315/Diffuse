import NativeRHI
import SceneRuntime
import SIMDCompat

struct NativeOverlayVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
    var barycentric: SIMD4<Float> = .zero
    var widths: SIMD4<Float> = .zero
    var edgeA: SIMD4<Float> = .zero
    var edgeB: SIMD4<Float> = .zero
    var edgeC: SIMD4<Float> = .zero
}

/// Only expansion and homogeneous clipping happen on the CPU. Visibility is
/// tested per fragment against scene depth, including partially hidden edges.
enum NativeOverlayGeometry {
    static let maximumVertices = 1_500_000

    static func make(_ overlay: RenderGeometryOverlay,matrix: simd_float4x4,pixelScale: Float = 1) throws -> [NativeOverlayVertex] {
        let count = overlay.triangles.count*3+overlay.lines.count*6+overlay.points.count*6
        guard count <= maximumVertices, pixelScale.isFinite,pixelScale > 0,overlay.viewportSize.x.isFinite,overlay.viewportSize.y.isFinite,
              overlay.viewportSize.x > 0,overlay.viewportSize.y > 0 else { throw RHIError.invalidArgument("invalid geometry overlay budget or viewport") }
        var result: [NativeOverlayVertex] = []; result.reserveCapacity(count)
        func projected(_ p: SIMD3<Float>) throws -> SIMD4<Float> {
            let clip = matrix*SIMD4(p,1)
            guard (0..<4).allSatisfy({ clip[$0].isFinite }) else { throw RHIError.invalidArgument("non-finite geometry overlay") }
            return clip
        }
        func append(_ p: SIMD4<Float>,_ color: SIMD4<Float>) throws {
            guard (0..<4).allSatisfy({ color[$0].isFinite }) else { throw RHIError.invalidArgument("non-finite overlay color") }
            var p = p
            // Small depth offset resolves coplanar roundoff without moving the
            // screen-space contour or bringing hidden walls to the foreground.
            p.z -= 0.000001*p.w
            result.append(.init(position: p,color: color))
        }
        for face in overlay.triangles {
            guard (0..<3).allSatisfy({ face.edgeWidths[$0].isFinite && face.edgeWidths[$0] >= 0 && face.edgeWidths[$0] <= 64 }),
                  [face.edgeA,face.edgeB,face.edgeC].allSatisfy({ c in (0..<4).allSatisfy { c[$0].isFinite } }) else {
                throw RHIError.invalidArgument("invalid surface wire style")
            }
            for (i,p) in [face.a,face.b,face.c].enumerated() {
                try append(projected(p),face.color)
                var barycentric = SIMD4<Float>.zero; barycentric[i] = 1
                result[result.count-1].barycentric = barycentric
                result[result.count-1].widths = SIMD4(face.edgeWidths*pixelScale,0)
                result[result.count-1].edgeA = face.edgeA; result[result.count-1].edgeB = face.edgeB; result[result.count-1].edgeC = face.edgeC
            }
        }
        func quad(_ corners: [SIMD4<Float>],color: SIMD4<Float>) throws {
            for i in [0,1,2,0,2,3] { try append(corners[i],color) }
        }
        for line in overlay.lines {
            guard line.width.isFinite,line.width > 0,line.width <= 64 else { throw RHIError.invalidArgument("invalid overlay line width") }
            guard let (a,b) = clipLine(try projected(line.a),try projected(line.b)) else { continue }
            let delta = SIMD2(b.x/b.w-a.x/a.w,b.y/b.w-a.y/a.w)*overlay.viewportSize
            let length = simd_length(delta)
            guard length > 1e-6 else { continue }
            let offset = SIMD2(-delta.y,delta.x)/length*line.width/overlay.viewportSize
            let oa = SIMD4(offset.x*a.w,offset.y*a.w,0,0), ob = SIMD4(offset.x*b.w,offset.y*b.w,0,0)
            try quad([a-oa,b-ob,b+ob,a+oa],color: line.color)
        }
        for point in overlay.points {
            guard point.size.isFinite,point.size > 0,point.size <= 128 else { throw RHIError.invalidArgument("invalid overlay marker size") }
            let p = try projected(point.position)
            guard p.w > 1e-6,p.z >= 0,p.z <= p.w else { continue }
            let r = point.size/overlay.viewportSize*p.w
            try quad([p+SIMD4(-r.x,-r.y,0,0),p+SIMD4(r.x,-r.y,0,0),p+SIMD4(r.x,r.y,0,0),p+SIMD4(-r.x,r.y,0,0)],color: point.color)
        }
        return result
    }

    static func clipLine(_ start: SIMD4<Float>,_ end: SIMD4<Float>) -> (SIMD4<Float>,SIMD4<Float>)? {
        var lo: Float = 0, hi: Float = 1
        let a = [start.w-1e-6,start.z,start.w-start.z,start.w+start.x,start.w-start.x,start.w+start.y,start.w-start.y]
        let b = [end.w-1e-6,end.z,end.w-end.z,end.w+end.x,end.w-end.x,end.w+end.y,end.w-end.y]
        for i in a.indices {
            if a[i] < 0 && b[i] < 0 { return nil }
            if (a[i] < 0) != (b[i] < 0) {
                let t = a[i]/(a[i]-b[i])
                if a[i] < 0 { lo = max(lo,t) } else { hi = min(hi,t) }
            }
        }
        guard lo <= hi else { return nil }
        return (start+(end-start)*lo,start+(end-start)*hi)
    }
}
