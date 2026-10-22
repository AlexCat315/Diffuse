internal import EditorCore
internal import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// The sections the task plugin described, such as products, targets and dependencies.
struct TaskProjectContents: View {
    let description: TaskProjectDescription?

    var body: some View {
        Column(alignment: .leading, spacing: 2) {
            (description?.sections ?? []).map { section in
                AnyView(Column(alignment: .leading, spacing: 2) {
                    Text(L(section.title), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceVariant)
                        .padding(EdgeInsets(top: 8, leading: 10, bottom: 2, trailing: 10))
                    section.items.map { item in
                        AnyView(Row(alignment: .center, spacing: 8) {
                            Text(item.name, lineLimit: 1).font(.mono).foregroundColor(.onSurface).flex(0, shrink: 1).frame(minWidth: 0)
                            Text(item.detail, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
                                .flex(1, shrink: 1).frame(minWidth: 0)
                        }.padding(horizontal: 14, vertical: 3).frame(width: .percent(100), minWidth: 0))
                    }
                })
            }
        }.frame(width: .percent(100), minWidth: 0).debugName("tasks-project")
    }
}
