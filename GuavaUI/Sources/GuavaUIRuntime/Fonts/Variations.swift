#if canImport(CoreText)
import CoreText
import CFreeType

/// A CoreText descriptor identifies a variable instance, not just a font file.
/// FreeType opens that file at its defaults; transfer the resolved design axes
/// before HarfBuzz and the atlas share the face. Optical size is chosen in
/// logical points, independently of the backing display's raster density.
func applyFontVariations(from font: CTFont, to face: FT_Face, library: FT_Library) -> Bool {
    guard face.pointee.face_flags & FT_Long(FT_FACE_FLAG_MULTIPLE_MASTERS) != 0 else { return true }
    var descriptor: UnsafeMutablePointer<FT_MM_Var>?
    guard FT_Get_MM_Var(face, &descriptor) == 0, let descriptor else { return false }
    defer { FT_Done_MM_Var(library, descriptor) }

    let values = CTFontCopyVariation(font) as? [NSNumber: NSNumber] ?? [:]
    let axes = UnsafeBufferPointer(start: descriptor.pointee.axis, count: Int(descriptor.pointee.num_axis))
    var coordinates = axes.map { axis -> FT_Fixed in
        guard let value = values[NSNumber(value: axis.tag)]?.doubleValue, value.isFinite else { return axis.def }
        let fixed = (value * 65_536).rounded()
        return FT_Fixed(min(Double(axis.maximum), max(Double(axis.minimum), fixed)))
    }
    return FT_Set_Var_Design_Coordinates(face, descriptor.pointee.num_axis, &coordinates) == 0
}
#endif
