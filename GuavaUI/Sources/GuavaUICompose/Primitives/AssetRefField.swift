import GuavaUIRuntime

public struct AssetRef: Sendable, Equatable {
    public let id: String
    public let name: String
    public let subtitle: String?
    public let kind: String

    public init(id: String,
                name: String,
                subtitle: String? = nil,
                kind: String) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.kind = kind
    }

    public init(payload: AssetDropPayload) {
        self.id = payload.id
        self.name = payload.name
        self.subtitle = payload.subtitle
        self.kind = payload.kind
    }
}

public struct AssetRefField: View {
    public let value: Binding<AssetRef?>
    public let activePayload: Binding<AssetDropPayload?>
    public let acceptedKinds: Set<String>
    public let placeholder: String
    public let isEnabled: Bool

    public init(value: Binding<AssetRef?>,
                activePayload: Binding<AssetDropPayload?> = .constant(nil),
                acceptedKinds: Set<String> = [],
                placeholder: String = "Drop asset",
                isEnabled: Bool = true) {
        self.value = value
        self.activePayload = activePayload
        self.acceptedKinds = acceptedKinds
        self.placeholder = placeholder
        self.isEnabled = isEnabled
    }

    public var body: some View {
        AssetDropTarget(activePayload: activePayload,
                        acceptedKinds: acceptedKinds,
                        isEnabled: isEnabled,
                        onDrop: { payload in
            value.wrappedValue = AssetRef(payload: payload)
        }) {
            Row(alignment: .center, spacing: 8) {
                AssetKindBadge(kind: value.wrappedValue?.kind,
                               isEnabled: isEnabled)

                Box(direction: .column, alignItems: .stretch, spacing: 1) {
                    Text(value.wrappedValue?.name ?? placeholder)
                        .font(.caption)
                        .foregroundColor(titleColor)
                        .flex(1, shrink: 1, basis: 0)
                        .clipped()

                    if let subtitle = value.wrappedValue?.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                            .flex(1, shrink: 1, basis: 0)
                            .clipped()
                    }
                }
                .flex(1, shrink: 1, basis: 0)
                .clipped()

                if value.wrappedValue != nil {
                    Button(role: .normal,
                           isEnabled: isEnabled,
                           action: {
                        value.wrappedValue = nil
                    }) {
                        Text("Clear")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    .buttonStyle(.ghost)
                }
            }
            .padding(horizontal: 6, vertical: 4)
            .frame(height: 32)
            .background(.surfaceSunken)
            .cornerRadius(4)
            .clipped()
        }
    }

    private var titleColor: SemanticColorRef {
        guard isEnabled else { return .onSurfaceMuted }
        return value.wrappedValue == nil ? .onSurfaceMuted : .onSurface
    }
}

private struct AssetKindBadge: View {
    let kind: String?
    let isEnabled: Bool

    var body: some View {
        Text((kind ?? "--").uppercased())
            .font(.caption)
            .foregroundColor(isEnabled ? .onSurfaceVariant : .onSurfaceMuted)
            .frame(width: 34, height: 20)
            .background(.surfaceOverlay)
            .cornerRadius(3)
    }
}
