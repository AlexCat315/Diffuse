import Foundation
import GuavaUIRuntime

/// Aspect-preserving, cancellable local-file preview using the shared loader.
public struct AsyncImageThumbnail<Placeholder: View>: View {
    public let path: String
    public let width: Float
    public let height: Float
    public let isEnabled: Bool
    public let placeholder: Placeholder
    public init(path: String, width: Float, height: Float, isEnabled: Bool = true,
                @ViewBuilder placeholder: () -> Placeholder) {
        self.path = path; self.width = width; self.height = height
        self.isEnabled = isEnabled; self.placeholder = placeholder()
    }
    public var body: some View {
        AsyncImage(url: URL(fileURLWithPath: path), width: width, height: height) { phase in
            switch phase {
            case .success(let image): AnyView(image)
            case .empty, .loading, .failure: AnyView(placeholder.frame(width: width, height: height))
            }
        }.opacity(isEnabled ? 1 : 0.55).clipped()
    }
}
