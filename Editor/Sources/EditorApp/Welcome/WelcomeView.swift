#if os(macOS)
import AppKit
#endif
import Foundation
import GuavaUICompose
import GuavaUIRuntime

struct WelcomeView: View {
    let context: EditorLaunchContext

    @State private var recentProjects: [String] = RecentProjectsStore.all()
    @State private var errorMessage: String? = nil

    var body: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 0) {
            Box(direction: .column, alignItems: .center, spacing: 8) {
                Text("GuavaNext Editor")
                    .font(.title)
                    .foregroundColor(.onSurface)
                Text("Select or create a project to get started.")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 0, vertical: 0)
            .padding(EdgeInsets(top: 0, leading: 0, bottom: 32, trailing: 0))

            if !recentProjects.isEmpty {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    Text(L("Recent Projects"))
                        .font(.label)
                        .foregroundColor(.onSurfaceMuted)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))

                    Box(direction: .column, alignItems: .stretch, spacing: 1) {
                        for path in recentProjects {
                            recentProjectRow(path: path)
                        }
                    }
                }
                .frame(width: 420)
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 24, trailing: 0))
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.error)
                    .padding(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
            }

            Row(alignment: .center, spacing: 12) {
                Button(L("New Project...")) {
                    pickNewProject()
                }
                .frame(width: 140)

                Button(L("Open Project...")) {
                    pickExistingProject()
                }
                .frame(width: 140)
            }
        }
        .background(.background)
        .flex()
    }

    private func recentProjectRow(path: String) -> AnyView {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return AnyView(
            Row(alignment: .center, spacing: 0) {
                Button(name) {
                    open(path: path)
                }
                .frame(minWidth: 0)
                .flex()

                Button("✕") {
                    RecentProjectsStore.remove(path)
                    recentProjects = RecentProjectsStore.all()
                }
                .frame(width: 28)
            }
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 4))
            .background(.surface)
        )
    }

    private func open(path: String) {
        Task { @MainActor [self] in
            errorMessage = nil
            do {
                try context.loadProject(directory: path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func pickExistingProject() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = L("Open Project")
        panel.message = L("Choose the root folder of your Guava project.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [self] in
                self.open(path: url.path)
            }
        }
        #endif
    }

    private func pickNewProject() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = L("New Project")
        panel.message = L("Choose a location and name for your new Guava project.")
        panel.nameFieldLabel = L("Project Name:")
        panel.nameFieldStringValue = "MyGame"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [self] in
                self.createAndOpen(at: url)
            }
        }
        #endif
    }

    private func createAndOpen(at url: URL) {
        Task { @MainActor [self] in
            errorMessage = nil
            let guavaDir = url.appendingPathComponent(".guava", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: guavaDir, withIntermediateDirectories: true)
                try context.loadProject(directory: url.path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
