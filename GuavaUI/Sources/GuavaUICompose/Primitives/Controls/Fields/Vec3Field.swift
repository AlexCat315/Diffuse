import Foundation
import GuavaUIRuntime

/// Three caller-owned numeric values with a shared format and constraints.
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
    public let locale: Locale

    public init(x: Binding<Float>, y: Binding<Float>, z: Binding<Float>,
                decimals: Int = 2, size: TextField.Size = .small, isEnabled: Bool = true,
                minValue: Float? = nil, maxValue: Float? = nil, step: Float? = nil,
                mixedAxes: Set<String> = [], mixedValueLabel: String = "Mixed value",
                locale: Locale = .current) {
        self.x = x; self.y = y; self.z = z
        self.decimals = decimals; self.size = size; self.isEnabled = isEnabled
        self.minValue = minValue; self.maxValue = maxValue; self.step = step
        self.mixedAxes = mixedAxes; self.mixedValueLabel = mixedValueLabel; self.locale = locale
    }

    public var body: some View {
        Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 4) {
            axis("X", color: Color(red: 211, green: 67, blue: 67), value: x)
            axis("Y", color: Color(red: 95, green: 173, blue: 86), value: y)
            axis("Z", color: Color(red: 78, green: 128, blue: 220), value: z)
        }
    }

    private func axis(_ label: String, color: Color, value: Binding<Float>) -> some View {
        Vec3AxisField(label: label, color: color,
            field: NumberField(value: value, decimals: decimals, size: size,
                isEnabled: isEnabled, minValue: minValue, maxValue: maxValue, step: step,
                mixedValueLabel: mixedAxes.contains(label.lowercased()) ? mixedValueLabel : nil,
                locale: locale))
            .flex(1, shrink: 1, basis: Self.axisBasis).frame(minWidth: Self.axisMinimumWidth)
    }

    static let axisBasis: Float = 96
    static let axisMinimumWidth: Float = 88
}

/// The adapter owns only the axis chrome; numeric configuration is copied as
/// one complete NumberField rather than mirrored through another field list.
private struct Vec3AxisField: View {
    let label: String
    let color: Color
    let field: NumberField

    var body: some View {
        SurfaceReader { surface in
            TextScalerReader { scaler in
                let height = max(scaler.scale(baseHeight), surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
                axisContent(height: height, labelWidth: scaler.scale(16))
            }
        }
    }

    private func axisContent(height: Float, labelWidth: Float) -> some View {
        Row(alignment: .center, spacing: 0) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(label).font(.label).foregroundColor(color)
            }
            .frame(width: labelWidth, height: height)
            .background(color.multipliedAlpha(field.isEnabled ? 0.13 : 0.06))
            field.frame(height: height).flex(1, shrink: 1, basis: 0).clipped()
        }
        .frame(height: height).background(.surfaceSunken).cornerRadius(.inputRadius).clipped()
    }

    private var baseHeight: Float {
        switch field.size {
        case .large: 40
        case .automatic, .regular: 32
        case .small: 28
        }
    }
}
