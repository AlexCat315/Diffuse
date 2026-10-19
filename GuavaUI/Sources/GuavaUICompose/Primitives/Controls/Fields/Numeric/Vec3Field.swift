import Foundation
import GuavaUIRuntime

/// Three caller-owned numeric values with a shared format and constraints.
///
/// Each axis is a `NumberField` led by its colored axis chip: drag a chip to
/// scrub that axis, double-click it to reset the axis to `resetValue`. The
/// row's context menu copies the vector, pastes one (`1, 2, 3`, `(1 2 3)` and
/// `Vector3(1, 2, 3)` all parse) and resets every axis.
public struct Vec3Field: View {
    public let x: Binding<Float>
    public let y: Binding<Float>
    public let z: Binding<Float>
    public let decimals: Int
    public let size: TextField.Size
    public let isEnabled: Bool
    public let minValue: Float?
    public let maxValue: Float?
    public let step: Float?
    public let mixedAxes: Set<String>
    public let mixedValueLabel: String
    public let resetValue: SIMD3<Float>?
    public let locale: Locale

    public init(x: Binding<Float>, y: Binding<Float>, z: Binding<Float>,
                decimals: Int = 2, size: TextField.Size = .small, isEnabled: Bool = true,
                minValue: Float? = nil, maxValue: Float? = nil, step: Float? = nil,
                mixedAxes: Set<String> = [], mixedValueLabel: String = "Mixed value",
                resetValue: SIMD3<Float>? = nil, locale: Locale = .current) {
        self.x = x; self.y = y; self.z = z
        self.decimals = decimals; self.size = size; self.isEnabled = isEnabled
        self.minValue = minValue; self.maxValue = maxValue; self.step = step
        self.mixedAxes = mixedAxes; self.mixedValueLabel = mixedValueLabel
        self.resetValue = resetValue; self.locale = locale
    }

    public var body: some View {
        AxisLayout(minimumWidth: CGFloat(Self.axisMinimumWidth), idealWidth: CGFloat(Self.axisBasis)) {
            axis("X", tint: Self.xTint, value: x, reset: resetValue?.x)
            axis("Y", tint: Self.yTint, value: y, reset: resetValue?.y)
            axis("Z", tint: Self.zTint, value: z, reset: resetValue?.z)
        }
        .contextMenu(onOpen: {}) { menu }
    }

    private func axis(_ label: String, tint: SemanticColorRef, value: Binding<Float>, reset: Float?) -> some View {
        NumberField(value: value, decimals: decimals, size: size,
                    isEnabled: isEnabled, minValue: minValue, maxValue: maxValue, step: step,
                    mixedValueLabel: mixedAxes.contains(label.lowercased()) ? mixedValueLabel : nil,
                    prefix: NumberField.Prefix(label, tint: tint), resetValue: reset, locale: locale)
            .frame(width: .percent(100))
    }

    private var menu: [MenuEntry] {
        let pasted = ClipboardHolder.read?().flatMap(Self.parse)
        var entries: [MenuEntry] = [
            .item(MenuItem(id: "copy", title: "Copy Vector") {
                ClipboardHolder.write?(Self.format(SIMD3(x.wrappedValue, y.wrappedValue, z.wrappedValue)))
            }),
            .item(MenuItem(id: "paste", title: "Paste Vector", isEnabled: isEnabled && pasted != nil) {
                guard let pasted else { return }
                write(pasted)
            })
        ]
        if let resetValue {
            entries.append(.separator("reset"))
            entries.append(.item(MenuItem(id: "reset", title: "Reset", isEnabled: isEnabled) { write(resetValue) }))
        }
        return entries
    }

    private func write(_ vector: SIMD3<Float>) {
        func clamp(_ value: Float) -> Float {
            var out = value
            if let minValue { out = max(minValue, out) }
            if let maxValue { out = min(maxValue, out) }
            return out
        }
        let next = SIMD3(clamp(vector.x), clamp(vector.y), clamp(vector.z))
        if x.wrappedValue != next.x { x.wrappedValue = next.x }
        if y.wrappedValue != next.y { y.wrappedValue = next.y }
        if z.wrappedValue != next.z { z.wrappedValue = next.z }
    }

    /// Locale-independent so a copied vector pastes the same everywhere.
    static func format(_ vector: SIMD3<Float>) -> String {
        [vector.x, vector.y, vector.z].map { $0.rounded() == $0 && abs($0) < 1e9 ? String(Int($0)) : String($0) }
            .joined(separator: ", ")
    }

    /// Three finite numbers separated by commas, semicolons or spaces, with
    /// optional brackets or a `Name(...)` wrapper.
    static func parse(_ text: String) -> SIMD3<Float>? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = body.firstIndex(where: { "([{".contains($0) }), let close = body.lastIndex(where: { ")]}".contains($0) }), open < close {
            body = String(body[body.index(after: open)..<close])
        }
        let parts = body.split(whereSeparator: { ",; \t\n".contains($0) }).compactMap { Float($0) }
        guard parts.count == 3, parts.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(parts[0], parts[1], parts[2])
    }

    static let axisBasis: Float = 96
    static let axisMinimumWidth: Float = 88
    static let xTint = SemanticColorRef { _ in Color(red: 211, green: 67, blue: 67) }
    static let yTint = SemanticColorRef { _ in Color(red: 95, green: 173, blue: 86) }
    static let zTint = SemanticColorRef { _ in Color(red: 78, green: 128, blue: 220) }
}
