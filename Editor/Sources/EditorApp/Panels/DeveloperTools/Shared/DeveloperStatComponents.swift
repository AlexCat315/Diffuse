import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct StatGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Row(alignment: .center, spacing: 6) {
                Box { EmptyView() }
                    .frame(width: 3, height: 16)
                    .background(.accent)
                    .cornerRadius(2)
                Text(title)
                    .lineLimit(1)
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                    .flex(1, shrink: 1)
            }
            .padding(horizontal: 10, vertical: 7)

            Column(alignment: .leading, spacing: 0) {
                content
            }
            .padding(horizontal: 4, vertical: 6)
        }
        .background(.surfaceSunken)
        .cornerRadius(6)
        .border(.border, width: 1)
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Text(label)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1, basis: 82)

            Text(value)
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(.onSurface)
                .flex(1, shrink: 1, basis: 70)
        }
        .padding(horizontal: 8, vertical: 2)
    }
}

struct StatWrappedValue: View {
    let label: String
    let value: String

    var body: some View {
        Column(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 8, vertical: 2)
            Text(value)
                .lineLimit(3)
                .font(.mono)
                .foregroundColor(.onSurface)
                .padding(horizontal: 8, vertical: 2)
        }
    }
}
