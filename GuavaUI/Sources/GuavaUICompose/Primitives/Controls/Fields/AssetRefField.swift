import GuavaUIRuntime

public struct AssetRef: Sendable, Equatable {
    public let id: String
    public let name: String
    public let subtitle: String?
    public let kind: String
    public let previewPath: String?

    public init(id: String,
                name: String,
                subtitle: String? = nil,
                kind: String,
                previewPath: String? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.kind = kind
        self.previewPath = previewPath
    }

    public init(payload: AssetDropPayload) {
        self.id = payload.id
        self.name = payload.name
        self.subtitle = payload.subtitle
        self.kind = payload.kind
        self.previewPath = payload.previewPath
    }
}

public struct AssetRefField: View {
    public let value: Binding<AssetRef?>
    public let activePayload: Binding<AssetDropPayload?>
    public let acceptedKinds: Set<String>
    public let pickerOptions: [AssetRef]
    public let placeholder: String
    public let isEnabled: Bool
    @State private var isPickerPresented = false

    public init(value: Binding<AssetRef?>,
                activePayload: Binding<AssetDropPayload?> = .constant(nil),
                acceptedKinds: Set<String> = [], pickerOptions: [AssetRef] = [],
                placeholder: String = "Drop asset", isEnabled: Bool = true) {
        self.value = value; self.activePayload = activePayload
        self.acceptedKinds = acceptedKinds; self.pickerOptions = pickerOptions
        self.placeholder = placeholder; self.isEnabled = isEnabled
    }

    public var body: some View {
        SurfaceReader { surface in
            TextScalerReader { scaler in
                field(minHeight: max(scaler.scale(32), surface.input.contains(.touch) ? 52 : 0))
            }
        }
    }

    private func field(minHeight: Float) -> some View {
        AssetDropTarget(activePayload: activePayload, acceptedKinds: acceptedKinds,
                        isEnabled: isEnabled, onDrop: { value.wrappedValue = AssetRef(payload: $0) }) {
            Row(alignment: .center, spacing: 8) {
                AssetRefPreview(ref: value.wrappedValue, isEnabled: isEnabled)
                    .flex(0, shrink: 0).accessibilityHidden()
                Box(direction: .column, alignItems: .stretch, spacing: 1) {
                    Text(value.wrappedValue?.name ?? placeholder)
                        .truncatingTail().tooltip(value.wrappedValue?.name ?? placeholder)
                        .font(.caption).foregroundColor(titleColor).flex(0, shrink: 1)
                    if let subtitle = value.wrappedValue?.subtitle, !subtitle.isEmpty {
                        Text(subtitle).truncatingTail().tooltip(subtitle)
                            .font(.caption).foregroundColor(.onSurfaceMuted).flex(0, shrink: 1)
                    }
                }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
                if value.wrappedValue != nil {
                    Button(icon: .resource(UIIcons.Action.x), size: 12,
                           isEnabled: isEnabled, tooltip: "Clear asset") { value.wrappedValue = nil }
                        .buttonStyle(.ghost).controlSize(.mini).accessibilityLabel("Clear asset")
                        .flex(0, shrink: 0).debugName("asset-clear")
                }
                if !pickerOptions.isEmpty { picker.flex(0, shrink: 0) }
            }
            .padding(horizontal: 6, vertical: 4).frame(minHeight: minHeight)
            .background(.surfaceSunken).cornerRadius(.inputRadius).clipped()
        }
        .accessibility {
            $0.role = .group; $0.label = value.wrappedValue?.name ?? placeholder
            $0.value = [value.wrappedValue?.kind, value.wrappedValue?.subtitle].compactMap { $0 }.joined(separator: " · ")
            $0.state.isEnabled = isEnabled; $0.combinesChildren = true
        }
    }

    private var picker: some View {
        var popover = Popover(isPresented: $isPickerPresented,
            isEnabled: isEnabled && !pickerMenuEntries.isEmpty,
            width: 240, placement: .bottomTrailing, surface: .content, overflow: .flip,
            triggerStyle: AnyButtonStyle(GhostButtonStyle())) {
                Icon(isPickerPresented ? UIIcons.Navigation.chevronUp : UIIcons.Navigation.chevronDown,
                     size: 12, color: .onSurfaceMuted)
            } content: {
                Menu(pickerMenuEntries, width: 240, maxVisibleRows: 9,
                     onItemActivated: { isPickerPresented = false })
            }
        popover.triggerDescription = PopoverTriggerDescription(label: "Choose asset", value: value.wrappedValue?.name ?? placeholder)
        return popover.controlSize(.mini).debugName("asset-picker")
    }

    private var titleColor: SemanticColorRef {
        !isEnabled || value.wrappedValue == nil ? .onSurfaceMuted : .onSurface
    }

    private var pickerMenuEntries: [MenuEntry] {
        pickerOptions.filter { acceptedKinds.isEmpty || acceptedKinds.contains($0.kind) }.map { option in
            .item(MenuItem(id: option.id, title: menuTitle(for: option),
                           isSelected: value.wrappedValue?.id == option.id) { value.wrappedValue = option })
        }
    }

    private func menuTitle(for option: AssetRef) -> String {
        guard let subtitle = option.subtitle, !subtitle.isEmpty else { return option.name }
        return "\(option.name)  \(subtitle)"
    }
}

private struct AssetKindBadge: View {
    let kind: String?
    let isEnabled: Bool

    var body: some View {
        Text(kind ?? "--").truncatingTail().tooltip(kind ?? "No asset")
            .font(.caption)
            // This is thumbnail artwork; the field's accessible value keeps
            // the full kind while its name and subtitle follow text scaling.
            .textScaler(.identity)
            .foregroundColor(isEnabled ? .onSurfaceVariant : .onSurfaceMuted)
            .padding(horizontal: 4, vertical: 2).frame(width: 34)
            .background(.surfaceOverlay)
            .cornerRadius(.rowRadius)
    }
}

private struct AssetRefPreview: View {
    let ref: AssetRef?
    let isEnabled: Bool

    var body: some View {
        if let previewPath = ref?.previewPath, !previewPath.isEmpty {
            AsyncImage(url: URL(fileURLWithPath: previewPath), width: 34, height: 24) {
                AssetKindBadge(kind: ref?.kind, isEnabled: isEnabled)
            }
            .opacity(isEnabled ? 1 : 0.55)
            .clipped()
            .background(.surfaceOverlay)
            .cornerRadius(.rowRadius)
        } else {
            AssetKindBadge(kind: ref?.kind, isEnabled: isEnabled)
        }
    }
}
