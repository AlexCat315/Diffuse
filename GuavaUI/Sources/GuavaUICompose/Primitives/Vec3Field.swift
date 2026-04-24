import GuavaUIRuntime

/// Compact three-axis numeric editor for inspector rows.
///
/// `Vec3Field` keeps the value controls shrinkable as a group, so a property
/// row can fit X/Y/Z edits inside narrow editor sidebars without text fields
/// escaping their grid cell.
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

    public init(x: Binding<Float>,
                y: Binding<Float>,
                z: Binding<Float>,
                decimals: Int = 2,
                size: TextField.Size = .small,
                isEnabled: Bool = true,
                minValue: Float? = nil,
                maxValue: Float? = nil,
                step: Float? = nil) {
        self.x = x
        self.y = y
        self.z = z
        self.decimals = decimals
        self.size = size
        self.isEnabled = isEnabled
        self.minValue = minValue
        self.maxValue = maxValue
        self.step = step
    }

    public var body: some View {
        Row(alignment: .center, spacing: 4) {
            Vec3AxisField(label: "X",
                          color: Color(red: 211, green: 67, blue: 67),
                          value: x,
                          decimals: decimals,
                          size: size,
                          isEnabled: isEnabled,
                          minValue: minValue,
                          maxValue: maxValue,
                          step: step)
                .flex(1, shrink: 1, basis: 0)

            Vec3AxisField(label: "Y",
                          color: Color(red: 95, green: 173, blue: 86),
                          value: y,
                          decimals: decimals,
                          size: size,
                          isEnabled: isEnabled,
                          minValue: minValue,
                          maxValue: maxValue,
                          step: step)
                .flex(1, shrink: 1, basis: 0)

            Vec3AxisField(label: "Z",
                          color: Color(red: 78, green: 128, blue: 220),
                          value: z,
                          decimals: decimals,
                          size: size,
                          isEnabled: isEnabled,
                          minValue: minValue,
                          maxValue: maxValue,
                          step: step)
                .flex(1, shrink: 1, basis: 0)
        }
        .clipped()
    }
}

private struct Vec3AxisField: View {
    let label: String
    let color: Color
    let value: Binding<Float>
    let decimals: Int
    let size: TextField.Size
    let isEnabled: Bool
    let minValue: Float?
    let maxValue: Float?
    let step: Float?

    var body: some View {
        Row(alignment: .center, spacing: 0) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(label)
                    .font(.label)
                    .foregroundColor(.onSurface)
            }
            .frame(width: 16, height: fieldHeight)
            .background(color.multipliedAlpha(isEnabled ? 0.85 : 0.35))

            NumberField(value: value,
                        decimals: decimals,
                        size: size,
                        isEnabled: isEnabled,
                        minValue: minValue,
                        maxValue: maxValue,
                        step: step)
                .frame(height: fieldHeight)
                .flex(1, shrink: 1, basis: 0)
                .clipped()
        }
        .frame(height: fieldHeight)
        .background(.surfaceSunken)
        .cornerRadius(3)
        .clipped()
    }

    private var fieldHeight: Float {
        switch size {
        case .large:
            return 40
        case .regular:
            return 32
        case .small:
            return 24
        }
    }
}
