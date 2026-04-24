import GuavaUIRuntime

/// Square button rendering a single icon as its label. Wraps `Button`
/// so it picks up every `ButtonStyle` (`.primary`, `.secondary`,
/// `.ghost`, `.destructive`) plus the standard hover/press/focus
/// animation behaviour.
///
/// Three construction paths cover the common cases:
///  - `IconButton(textureID:)` — caller already owns a registered
///    `TextureID` (e.g. via the font atlas or a custom upload).
///  - `IconButton(file:)` — loads the file through
///    `ImageAssetRegistryHolder.current` (PNG/JPEG/HEIC/SVG/...).
///  - `IconButton(systemSymbol:)` reserved for a future SF-symbols
///    pipeline; not implemented yet.
///
/// `size` is the rendered glyph edge length in logical points; the
/// surrounding button picks up its own padding from the active style,
/// so `.ghost` icon buttons in toolbars are visually compact while
/// `.primary` icon buttons grow to match the text-button rhythm.
///
/// Leave `tint` as `nil` (default) to inherit semantic foreground from the
/// active `ButtonStyle` label container. Pass a color only when a fixed icon
/// tint is required regardless of style role.
public struct IconButton: View {

    public enum Source {
        /// Pre-registered texture (e.g. via `DrawListRenderer.registerColorTexture`).
        case texture(TextureID)
        /// File on disk, resolved at view-construction time through
        /// `ImageAssetRegistryHolder.current`.
        case file(path: String)
        /// Bundle-packaged image resource resolved by the UI layer.
        case resource(BundleImageResource)
    }

    public let source: Source
    public let size: Float
    public let role: ButtonRole
    public let isEnabled: Bool
    public let tooltip: String?
    public let tint: Color?
    public let action: () -> Void

    public init(textureID: TextureID,
                size: Float = 16,
                role: ButtonRole = .normal,
                isEnabled: Bool = true,
                tooltip: String? = nil,
                tint: Color? = nil,
                action: @escaping () -> Void) {
        self.source = .texture(textureID)
        self.size = size
        self.role = role
        self.isEnabled = isEnabled
        self.tooltip = tooltip
        self.tint = tint
        self.action = action
    }

    public init(file path: String,
                size: Float = 16,
                role: ButtonRole = .normal,
                isEnabled: Bool = true,
                tooltip: String? = nil,
                tint: Color? = nil,
                action: @escaping () -> Void) {
        self.source = .file(path: path)
        self.size = size
        self.role = role
        self.isEnabled = isEnabled
        self.tooltip = tooltip
        self.tint = tint
        self.action = action
    }

    public init(resource: BundleImageResource,
                size: Float = 16,
                role: ButtonRole = .normal,
                isEnabled: Bool = true,
                tooltip: String? = nil,
                tint: Color? = nil,
                action: @escaping () -> Void) {
        self.source = .resource(resource)
        self.size = size
        self.role = role
        self.isEnabled = isEnabled
        self.tooltip = tooltip
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(role: role, isEnabled: isEnabled, tooltip: tooltip, action: action) {
            iconView
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch source {
        case .texture(let id):
            Image(textureID: id,
                  width: size,
                  height: size,
                  tint: tint ?? .white,
                  renderingMode: .alphaMask)
        case .file(let path):
            Image(file: path,
                  width: size,
                  height: size,
                  tint: tint ?? .white,
                  contentMode: .fit,
                  renderingMode: .alphaMask)
        case .resource(let resource):
            Image(resource: resource,
                  width: size,
                  height: size,
                  tint: tint ?? .white,
                  contentMode: .fit,
                  renderingMode: .alphaMask)
        }
    }
}
