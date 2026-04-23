import Foundation
import GuavaUIRuntime

// MARK: - Public API

/// Compact color picker: a colored swatch button that opens an RGBA channel
/// editor popover. Suitable for inspector rows and tool palettes.
///
/// ```swift
/// @State var tint = Color(r: 1, g: 0.5, b: 0, a: 1)
/// ColorField(color: $tint)
/// ```
///
/// The popover contains per-channel sliders (R / G / B / A) in the 0–1 range,
/// mirrored integer fields (0–255), and a hex text field (`#RRGGBB` or
/// `#RRGGBBAA` when `showAlpha` is true).
public struct ColorField: View {
    public let color: Binding<Color>
    public let isEnabled: Bool
    public let showAlpha: Bool
    public let showsInlineValues: Bool

    public init(color: Binding<Color>,
                isEnabled: Bool = true,
                showAlpha: Bool = true,
                showsInlineValues: Bool = false) {
        self.color = color
        self.isEnabled = isEnabled
        self.showAlpha = showAlpha
        self.showsInlineValues = showsInlineValues
    }

    public var body: some View {
        _StatefulColorField(field: self)
    }
}

// MARK: - Stateful wrapper

private struct _StatefulColorField: View {
    let field: ColorField

    @State var isPresented: Bool = false

    var body: some View {
        Popover(isPresented: $isPresented,
                isEnabled: field.isEnabled,
                label: {
            ColorSwatch(color: field.color.wrappedValue,
                        isEnabled: field.isEnabled,
                        showAlpha: field.showAlpha,
                        showsInlineValues: field.showsInlineValues)
        }, content: {
            ColorPickerPanel(color: field.color, showAlpha: field.showAlpha)
                .padding(10)
                .frame(width: 220)
                .background(.surfaceFloating)
                .cornerRadius(8)
        })
    }
}

// MARK: - Swatch button (label)

private struct ColorSwatch: View {
    let color: Color
    let isEnabled: Bool
    let showAlpha: Bool
    let showsInlineValues: Bool

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Box(direction: .row, alignItems: .center, spacing: 0) {}
                .frame(width: 52, height: 22)
                .background(isEnabled ? color : color.multipliedAlpha(0.4))
                .cornerRadius(3)
                .border(Color(red: 58, green: 64, blue: 78), width: 1)

            if showsInlineValues {
                Text(hexString(from: color, showAlpha: showAlpha))
                    .font(.mono)
                    .foregroundColor(isEnabled ? .onSurfaceVariant : .onSurfaceMuted)
                Text(rgbString(from: color, showAlpha: showAlpha))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .flex()
            }
        }
    }

    private func hexString(from c: Color, showAlpha: Bool) -> String {
        let r = clamp8(c.r)
        let g = clamp8(c.g)
        let b = clamp8(c.b)
        if showAlpha {
            let a = clamp8(c.a)
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func rgbString(from c: Color, showAlpha: Bool) -> String {
        let r = clamp8(c.r)
        let g = clamp8(c.g)
        let b = clamp8(c.b)
        if showAlpha {
            let a = clamp8(c.a)
            return "\(r), \(g), \(b), \(a)"
        }
        return "\(r), \(g), \(b)"
    }

    private func clamp8(_ v: Float) -> Int {
        Int((v * 255).rounded()).clamped(to: 0...255)
    }
}

// MARK: - Picker panel

private struct ColorPickerPanel: View {
    let color: Binding<Color>
    let showAlpha: Bool

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 8) {
            // Preview swatch
            Box(direction: .row, alignItems: .center, spacing: 0) {}
                .frame(height: 28)
                .background(color.wrappedValue)
                .cornerRadius(4)
                .border(Color(red: 58, green: 64, blue: 78), width: 1)

            // R / G / B channel rows
            channelRow("R",
                       value: Binding(
                           get: { Double(color.wrappedValue.r) },
                           set: { color.wrappedValue.r = Float(max(0, min(1, $0))) }
                       ))
            channelRow("G",
                       value: Binding(
                           get: { Double(color.wrappedValue.g) },
                           set: { color.wrappedValue.g = Float(max(0, min(1, $0))) }
                       ))
            channelRow("B",
                       value: Binding(
                           get: { Double(color.wrappedValue.b) },
                           set: { color.wrappedValue.b = Float(max(0, min(1, $0))) }
                       ))

            if showAlpha {
                channelRow("A",
                           value: Binding(
                               get: { Double(color.wrappedValue.a) },
                               set: { color.wrappedValue.a = Float(max(0, min(1, $0))) }
                           ))
            }

            // Hex input
            _HexField(color: color, showAlpha: showAlpha)
        }
    }

    private func channelRow(_ label: String,
                            value: Binding<Double>) -> some View {
        Row(alignment: .center, spacing: 6) {
            Text(label)
                .font(.label)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: 10)

            Slider(value: value, range: 0...1)
                .flex()

            // Integer display 0–255
            Text(String(Int((value.wrappedValue * 255).rounded())))
                .font(.mono)
                .foregroundColor(.onSurfaceVariant)
                .frame(width: 26)
        }
    }
}

// MARK: - Hex field

private struct _HexField: View {
    let color: Binding<Color>
    let showAlpha: Bool

    var body: some View {
        _StatefulHexField(color: color, showAlpha: showAlpha)
    }
}

private struct _StatefulHexField: View {
    let color: Binding<Color>
    let showAlpha: Bool

    @State var draft: String = ""
    @State var isEditing: Bool = false

    var body: some View {
        let committed = hexString(from: color.wrappedValue, showAlpha: showAlpha)
        Row(alignment: .center, spacing: 6) {
            Text("HEX")
                .font(.label)
                .foregroundColor(.onSurfaceMuted)
            TextField(
                text: Binding(
                    get: { isEditing ? draft : committed },
                    set: { draft = $0 }
                ),
                onSubmit: { commitHex() },
                onFocus: {
                    if !isEditing {
                        draft = committed
                        isEditing = true
                    }
                },
                onBlur: {
                    commitHex()
                    isEditing = false
                }
            )
            .flex()
        }
    }

    private func commitHex() {
        if let parsed = parseHex(draft) {
            color.wrappedValue = parsed
        }
    }

    private func hexString(from c: Color, showAlpha: Bool) -> String {
        let r = clamp8(c.r)
        let g = clamp8(c.g)
        let b = clamp8(c.b)
        if showAlpha {
            let a = clamp8(c.a)
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func clamp8(_ v: Float) -> Int {
        Int((v * 255).rounded()).clamped(to: 0...255)
    }

    private func parseHex(_ text: String) -> Color? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch s.count {
        case 6:
            guard let val = UInt32(s, radix: 16) else { return nil }
            return Color(
                red:   UInt8((val >> 16) & 0xFF),
                green: UInt8((val >> 8)  & 0xFF),
                blue:  UInt8(val         & 0xFF)
            )
        case 8:
            guard let val = UInt32(s, radix: 16) else { return nil }
            return Color(
                red:   UInt8((val >> 24) & 0xFF),
                green: UInt8((val >> 16) & 0xFF),
                blue:  UInt8((val >> 8)  & 0xFF),
                alpha: UInt8(val         & 0xFF)
            )
        default:
            return nil
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
