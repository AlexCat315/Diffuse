import Foundation
import GuavaUICompose

struct EditorAboutView: View {
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (.some(version), .some(build)) where version != build:
            return "\(L("Version")) \(version) (\(build))"
        case let (.some(version), _):
            return "\(L("Version")) \(version)"
        default:
            return L("Development Build")
        }
    }

    var body: some View {
        Box(direction: .column,
            alignItems: .center,
            justifyContent: .center,
            spacing: 12) {
            Text("GuavaNext Editor")
                .font(.title)
                .foregroundColor(.onSurface)

            Text(versionText)
                .font(.body)
                .foregroundColor(.onSurfaceVariant)

            Text(L("A native scene editor powered by Guava Engine."))
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            Text("© 2026 Guava Engine")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(28)
        .background(.surface)
    }
}
