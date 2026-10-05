import Foundation
import SIMDCompat

/// Quantizes only the active transform tool, preserving the other components.
public enum EditorTransformSnapping {
    public static func apply(_ matrix: simd_float4x4,
                             mode: EditorGizmoController.Mode,
                             state: EditorState) -> simd_float4x4 {
        var result = matrix
        switch mode {
        case .translate:
            guard state.translateSnapEnabled else { return result }
            let step = EditorState.sanitizedTranslateSnapStep(state.translateSnapStep)
            result.columns.3.x = quantize(result.columns.3.x, step: step)
            result.columns.3.y = quantize(result.columns.3.y, step: step)
            result.columns.3.z = quantize(result.columns.3.z, step: step)
            return result
        case .rotate:
            guard state.rotateSnapEnabled else { return result }
            let snapped = snapRotation(result, stepDegrees: EditorState.sanitizedRotateSnapStep(state.rotateSnapStepDegrees))
            return snapped
        case .scale:
            guard state.scaleSnapEnabled else { return result }
            let snapped = snapScale(result, step: EditorState.sanitizedScaleSnapStep(state.scaleSnapStep), minScale: 0.001)
            return snapped
        }
    }

    private static func snapRotation(_ matrix: simd_float4x4,
                                     stepDegrees: Float) -> simd_float4x4 {
        let decomp = decomposeTRS(matrix)
        let euler = quaternionToEulerXYZ(decomp.rotation)
        let step = stepDegrees * (.pi / 180)
        let snappedEuler = SIMD3<Float>(
            quantize(euler.x, step: step),
            quantize(euler.y, step: step),
            quantize(euler.z, step: step)
        )
        let snappedQ = eulerXYZToQuaternion(snappedEuler)
        return composeTRS(translation: decomp.translation,
                          rotation: snappedQ,
                          scale: decomp.scale)
    }

    private static func snapScale(_ matrix: simd_float4x4,
                                  step: Float,
                                  minScale: Float) -> simd_float4x4 {
        let decomp = decomposeTRS(matrix)
        let snapped = SIMD3<Float>(
            max(minScale, quantize(decomp.scale.x, step: step)),
            max(minScale, quantize(decomp.scale.y, step: step)),
            max(minScale, quantize(decomp.scale.z, step: step))
        )
        return composeTRS(translation: decomp.translation,
                          rotation: decomp.rotation,
                          scale: snapped)
    }

    private static func quantize(_ value: Float, step: Float) -> Float {
        guard step > 1e-6 else { return value }
        return (value / step).rounded() * step
    }

    private static func decomposeTRS(_ matrix: simd_float4x4)
        -> (translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
        let t = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
        let c0 = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
        let c1 = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
        let c2 = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        let sx = max(simd_length(c0), 1e-8)
        let sy = max(simd_length(c1), 1e-8)
        let sz = max(simd_length(c2), 1e-8)
        let r0 = c0 / sx
        let r1 = c1 / sy
        let r2 = c2 / sz
        let rotM = simd_float3x3(columns: (r0, r1, r2))
        return (t, simd_quatf(rotM), SIMD3<Float>(sx, sy, sz))
    }

    private static func composeTRS(translation t: SIMD3<Float>,
                                   rotation r: simd_quatf,
                                   scale s: SIMD3<Float>) -> simd_float4x4 {
        let rm = simd_float3x3(r)
        var out = matrix_identity_float4x4
        out.columns.0 = SIMD4<Float>(rm.columns.0 * s.x, 0)
        out.columns.1 = SIMD4<Float>(rm.columns.1 * s.y, 0)
        out.columns.2 = SIMD4<Float>(rm.columns.2 * s.z, 0)
        out.columns.3 = SIMD4<Float>(t, 1)
        return out
    }

    private static func quaternionToEulerXYZ(_ q: simd_quatf) -> SIMD3<Float> {
        let x = q.imag.x
        let y = q.imag.y
        let z = q.imag.z
        let w = q.real

        let sinrCosp = 2 * (w * x + y * z)
        let cosrCosp = 1 - 2 * (x * x + y * y)
        let roll = atan2f(sinrCosp, cosrCosp)

        let sinp = 2 * (w * y - z * x)
        let pitch: Float
        if abs(sinp) >= 1 {
            pitch = copysignf(.pi * 0.5, sinp)
        } else {
            pitch = asinf(sinp)
        }

        let sinyCosp = 2 * (w * z + x * y)
        let cosyCosp = 1 - 2 * (y * y + z * z)
        let yaw = atan2f(sinyCosp, cosyCosp)

        return SIMD3<Float>(roll, pitch, yaw)
    }

    private static func eulerXYZToQuaternion(_ euler: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(angle: euler.x, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: euler.y, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 0, 1))
        return qz * qy * qx
    }
}

public extension EditorState {
    static func sanitizedTranslateSnapStep(_ value: Float) -> Float {
        sanitizedSnapStep(value, maximum: 10_000, fallback: 0.5)
    }
    static func sanitizedRotateSnapStep(_ value: Float) -> Float {
        sanitizedSnapStep(value, maximum: 180, fallback: 5)
    }
    static func sanitizedScaleSnapStep(_ value: Float) -> Float {
        sanitizedSnapStep(value, maximum: 10, fallback: 0.05)
    }
    private static func sanitizedSnapStep(_ value: Float, maximum: Float, fallback: Float) -> Float {
        guard value.isFinite, value > 0 else { return fallback }
        return min(max(value, 0.001), maximum)
    }
}
