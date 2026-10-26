internal import EditorCore
internal import Foundation
internal import CoveUI
internal import CoveUIRuntime

/// Tests by group, each with its last result and a run button. The language
/// service finds them; a failing test shows the first issue it recorded.
struct TestExplorer: View {
    let model: EditorTasks
    let snapshot: TaskSnapshot

    var body: some View {
        let busy = snapshot.run?.isRunning == true
        Column(alignment: .leading, spacing: 0) {
            groups.map { group in
                AnyView(Column(alignment: .leading, spacing: 0) {
                    Text(group.title, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceVariant)
                        .padding(EdgeInsets(top: 6, leading: 10, bottom: 2, trailing: 10))
                    group.tests.map { test in AnyView(row(test, busy: busy)) }
                })
            }
        }.frame(width: .percent(100), minWidth: 0).debugName("tasks-tests")
    }

    private var groups: [(title: String, tests: [TaskTest])] {
        var order: [String] = [], members: [String: [TaskTest]] = [:]
        for test in snapshot.tests {
            if members[test.group] == nil { order.append(test.group) }
            members[test.group, default: []].append(test)
        }
        return order.map { ($0, members[$0] ?? []) }
    }

    private func row(_ test: TaskTest, busy: Bool) -> some View {
        Column(alignment: .leading, spacing: 1) {
            Row(alignment: .center, spacing: 6) {
                if test.status == .running { Spinner(size: 10) } else {
                    Icon(icon(test.status), size: 11, color: color(test.status))
                }
                Text(test.name, lineLimit: 1).font(.mono).foregroundColor(.onSurface).flex(1, shrink: 1).frame(minWidth: 0)
                Button(icon: .resource(UIIcons.Editor.play), size: 9, isEnabled: !busy, tooltip: L("Run Test")) {
                    model.test(test.id)
                }.buttonStyle(ToggleButtonStyle(height: 20))
            }.frame(width: .percent(100), minWidth: 0)
            if let message = test.message, test.status == .failed {
                Text(message, lineLimit: 3).font(.caption).foregroundColor(.error).padding(EdgeInsets(leading: 17))
            }
        }.padding(horizontal: 14, vertical: 2).frame(width: .percent(100), minWidth: 0)
            .accessibility { $0.label = test.id }
    }

    private func icon(_ status: TaskTest.Status) -> BundleImageResource {
        switch status {
        case .passed: UIIcons.Status.checkCircle
        case .failed: UIIcons.Status.xCircle
        case .skipped: UIIcons.Shape.circleDot
        case .notRun, .running: UIIcons.Shape.circle
        }
    }

    private func color(_ status: TaskTest.Status) -> SemanticColorRef {
        switch status {
        case .passed: .success
        case .failed: .error
        case .skipped, .notRun, .running: .onSurfaceMuted
        }
    }
}
