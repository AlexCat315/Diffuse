import Foundation
import SIMDCompat

func vec3ToJSON(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
func vec4ToJSON(_ v: SIMD4<Float>) -> [Float] { [v.x, v.y, v.z, v.w] }
func matrixToJSON(_ matrix: simd_float4x4) -> [Float] {
    [matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
     matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
     matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
     matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w]
}
func jsonToMatrix(_ values: [Float]) -> simd_float4x4? {
    guard values.count == 16 else { return nil }
    return simd_float4x4(columns: (
        SIMD4<Float>(values[0], values[1], values[2], values[3]),
        SIMD4<Float>(values[4], values[5], values[6], values[7]),
        SIMD4<Float>(values[8], values[9], values[10], values[11]),
        SIMD4<Float>(values[12], values[13], values[14], values[15])
    ))
}
func jsonToVec3(_ a: [Float]) -> SIMD3<Float>? {
    a.count == 3 ? SIMD3<Float>(a[0], a[1], a[2]) : nil
}
func jsonToVec4(_ a: [Float]) -> SIMD4<Float>? {
    a.count == 4 ? SIMD4<Float>(a[0], a[1], a[2], a[3]) : nil
}
func jsonToFloat(_ val: Any?) -> Float? {
    (val as? NSNumber).map { Float(truncating: $0) }
}
func jsonToDouble(_ val: Any?) -> Double? {
    (val as? NSNumber).map { Double(truncating: $0) }
}
func jsonToBool(_ val: Any?) -> Bool? { val as? Bool }
func jsonToString(_ val: Any?) -> String? { val as? String }
func jsonToInt(_ val: Any?) -> Int? { (val as? NSNumber).map { Int(truncating: $0) } }
func jsonToDict(_ val: Any?) -> [String: Any]? { val as? [String: Any] }
func jsonToArray(_ val: Any?) -> [Any]? { val as? [Any] }
func jsonToStringFloatDict(_ val: Any?) -> [String: Float]? {
    guard let dict = val as? [String: Any] else { return nil }
    var out: [String: Float] = [:]
    for (key, value) in dict {
        if let number = value as? NSNumber {
            out[key] = Float(truncating: number)
        }
    }
    return out
}
func jsonToFloatArray(_ val: Any?) -> [Float]? {
    (val as? [Any])?.compactMap { ($0 as? NSNumber).map { Float(truncating: $0) } }
}
func encodeJSONValue<T: Encodable>(_ value: T) -> Any? {
    guard let data = try? JSONEncoder().encode(value) else {
        return nil
    }
    return try? JSONSerialization.jsonObject(with: data)
}
func decodeJSONValue<T: Decodable>(_ value: Any?, as type: T.Type) -> T? {
    guard let value,
          JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value) else {
        return nil
    }
    return try? JSONDecoder().decode(type, from: data)
}

