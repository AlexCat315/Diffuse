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
                AssetRefPreview(ref: value.wrappedValue, acceptedKinds: acceptedKinds, isEnabled: isEnabled)
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
            .background(.surface).cornerRadius(.inputRadius).border(.border, width: 1).clipped()
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

/// Thumbnail stand-in when an asset has no preview image: a glyph for its
/// kind. Kind strings are free-form ("image", "Texture", "Static Mesh"), so
/// they match by keyword; the full kind stays in the tooltip and the field's
/// accessible value instead of being truncated into a 34pt tile.
struct AssetKindTile: View {
    let kind: String?
    let isEnabled: Bool
    /// True when the tile previews what the empty field accepts.
    var isPlaceholder = false

    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            Icon(Self.icon(for: kind), size: 14,
                 color: !isEnabled || isPlaceholder ? .onSurfaceMuted : .onSurfaceVariant)
        }
        .frame(width: 34, height: 24)
        .background(.surfaceVariant)
        .cornerRadius(.rowRadius)
        .tooltip(kind ?? "No asset")
    }

    static func icon(for kind: String?) -> BundleImageResource {
        guard let kind = kind?.lowercased() else { return UIIcons.File.file }
        let groups: [([String], BundleImageResource)] = [
            (["image", "texture", "sprite", "png", "jpg", "jpeg", "webp", "svg"], UIIcons.Media.image),
            (["mesh", "model", "gltf", "glb", "obj"], UIIcons.Editor.box),
            (["material", "shader"], UIIcons.Editor.brush),
            (["audio", "sound", "music", "wav", "mp3"], UIIcons.Media.music),
            (["video", "movie", "mp4"], UIIcons.Media.video),
            (["scene", "prefab", "level"], UIIcons.Editor.layers),
            (["script", "code", "swift"], UIIcons.File.fileCode),
            (["text", "json", "document"], UIIcons.File.fileText),
            (["package", "bundle", "archive"], UIIcons.File.package),
        ]
        return groups.first { keywords, _ in keywords.contains { kind.contains($0) } }?.1 ?? UIIcons.File.file
    }
}

private struct AssetRefPreview: View {
    let ref: AssetRef?
    let acceptedKinds: Set<String>
    let isEnabled: Bool

    var body: some View {
        if let previewPath = ref?.previewPath, !previewPath.isEmpty {
            AsyncImage(url: URL(fileURLWithPath: previewPath), width: 34, height: 24) {
                tile
            }
            .opacity(isEnabled ? 1 : 0.55)
            .clipped()
            .background(.surfaceVariant)
            .cornerRadius(.rowRadius)
        } else {
            tile
        }
    }

    /// An empty field that accepts one kind shows that kind's glyph, muted,
    /// as a hint of what it takes.
    private var tile: AssetKindTile {
        if let ref { return AssetKindTile(kind: ref.kind, isEnabled: isEnabled) }
        return AssetKindTile(kind: acceptedKinds.count == 1 ? acceptedKinds.first : nil,
                             isEnabled: isEnabled, isPlaceholder: true)
    }
}
