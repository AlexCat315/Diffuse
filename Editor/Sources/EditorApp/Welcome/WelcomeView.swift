import EditorCore
import Foundation
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime

struct WelcomeView: View {
    let context: EditorLaunchContext

    @State private var recentProjects: [String] = RecentProjectsStore.all()
    @State private var errorMessage: String? = nil
    @State private var template: EditorProjectTemplate? = nil
    @State private var projectName: TextBuffer = "NewGame"
    @State private var parentPath = TextBuffer(Self.defaultParent.path)
    @State private var deletionPath: String? = nil

    private static var defaultParent: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let documents, FileManager.default.fileExists(atPath: documents.path) { return documents }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    var body: some View {
        LayerRoot {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                ImmersiveWindowTitleBar {
                    Text("GuavaNext Editor").font(.label).foregroundColor(.onSurfaceMuted)
                }
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Box(direction: .column, alignItems: .center, spacing: 24) {
                        Column(alignment: .leading, spacing: 8) {
                            Text("GuavaNext Editor").font(.title).foregroundColor(.onSurface)
                            Text(L("Create a blank project, open your work, or try a playable example."))
                                .font(.body).foregroundColor(.onSurfaceMuted)
                        }.frame(width: 900)

                        Row(alignment: .top, spacing: 24) {
                            Column(alignment: .leading, spacing: 16) {
                                Text(L("Projects")).font(.headline).foregroundColor(.onSurface)
                                Row(alignment: .center, spacing: 8) {
                                    Button(L("New Project...")) { beginCreation(.blank) }.debugName("welcome-new-project")
                                    Button(L("Open Project...")) { pickExistingProject() }.buttonStyle(.secondary)
                                }
                                if let errorMessage {
                                    Text(errorMessage).font(.caption).foregroundColor(.error)
                                }
                                if template != nil { creationForm }
                                exampleCard
                            }.frame(width: 420)

                            Column(alignment: .leading, spacing: 10) {
                                Text(L("Recent Projects")).font(.headline).foregroundColor(.onSurface)
                                Text(L("Removing a recent entry keeps its files. Delete moves the project to Trash."))
                                    .font(.caption).foregroundColor(.onSurfaceMuted)
                                if recentProjects.isEmpty {
                                    Text(L("No recent projects yet.")).font(.body).foregroundColor(.onSurfaceMuted)
                                        .padding(16)
                                }
                                for path in recentProjects { recentProjectRow(path: path) }
                            }.frame(width: 456)
                        }.frame(width: 900)
                    }.padding(32)
                }.flex()
            }.background(.background).flex()
        } portals: {
            PortalHost()
            if let deletionPath { deletionDialog(path: deletionPath) }
        }
    }

    private var exampleCard: some View {
        Column(alignment: .leading, spacing: 10) {
            Text(L("Playable Example")).font(.label).foregroundColor(.onSurfaceMuted)
            Text("Crystal Rush").font(.headline).foregroundColor(.onSurface)
            Text(L("Collect 8 crystals in 50 seconds and avoid the sentinels. Includes the complete editable game script."))
                .font(.body).foregroundColor(.onSurfaceVariant)
            Text(L("Play → Space to start · WASD move · Shift sprint · R restart"))
                .font(.caption).foregroundColor(.onSurfaceMuted)
            Button(L("Create Example Project...")) { beginCreation(.crystalRush) }.buttonStyle(.secondary).debugName("welcome-example-project")
        }.padding(18).frame(width: .percent(100)).background(.surface).cornerRadius(10)
    }

    private var creationForm: some View {
        Column(alignment: .leading, spacing: 10) {
            Text(L(template == .crystalRush ? "New Crystal Rush Project" : "New Blank Project"))
                .font(.headline).foregroundColor(.onSurface)
            Text(L("Project Name")).font(.label).foregroundColor(.onSurfaceMuted)
            TextField(L("Project Name"), text: $projectName).debugName("welcome-project-name")
            Text(L("Parent Folder")).font(.label).foregroundColor(.onSurfaceMuted)
            Row(alignment: .center, spacing: 6) {
                TextField(L("Parent Folder"), text: $parentPath).flex().debugName("welcome-project-parent")
                Button(L("Browse...")) { pickParent() }.buttonStyle(.secondary)
            }
            Text(URL(fileURLWithPath: (parentPath.stringValue as NSString).expandingTildeInPath)
                .appendingPathComponent(projectName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)).path)
                .font(.caption).foregroundColor(.onSurfaceMuted)
            Text(L(template == .crystalRush
                   ? "Creates a separate copy and compiles its bundled script. When ready, click Play."
                   : "Starts with an empty scene and empty Assets and Scripts folders."))
                .font(.caption).foregroundColor(.onSurfaceMuted)
            Row(alignment: .center, spacing: 8) {
                Button(L("Create and Open")) { createProject() }.debugName("welcome-create-project")
                Button(L("Cancel")) { template = nil; errorMessage = nil }.buttonStyle(.ghost).debugName("welcome-cancel-creation")
            }
        }.padding(18).frame(width: .percent(100)).background(.surface).cornerRadius(10)
    }

    private func recentProjectRow(path: String) -> AnyView {
        let location = try? EditorProjectLifecycle.inspect(URL(fileURLWithPath: path), validateScene: false)
        let name = location?.name ?? URL(fileURLWithPath: path).lastPathComponent
        return AnyView(Column(alignment: .leading, spacing: 6) {
            Row(alignment: .center, spacing: 8) {
                Button(name) { open(path: path) }.buttonStyle(.ghost).flex()
                Button(L("Remove Entry")) {
                    RecentProjectsStore.remove(path)
                    recentProjects = RecentProjectsStore.all()
                }.buttonStyle(.ghost)
                if location?.descriptor != nil {
                    Button(L("Delete"), role: .destructive) { deletionPath = path }.buttonStyle(.ghost)
                }
            }
            Text(path).font(.caption).foregroundColor(.onSurfaceMuted)
            if location == nil {
                Text(L("Missing or invalid project — open its new location or remove this entry."))
                    .font(.caption).foregroundColor(.warning)
            }
        }.padding(12).frame(width: .percent(100)).background(.surface).cornerRadius(8))
    }

    private func deletionDialog(path: String) -> some View {
        ModalBarrier {
            Column(alignment: .leading, spacing: 12) {
                Text(L("Move Project to Trash?")).font(.headline).foregroundColor(.onSurface)
                Text(path).font(.body).foregroundColor(.onSurfaceVariant)
                Text(L("This moves the entire project folder, including assets and scripts. You can restore it from Trash."))
                    .font(.body).foregroundColor(.onSurfaceMuted)
                Row(alignment: .center, spacing: 8) {
                    Spacer(minLength: 0)
                    Button(L("Cancel")) { deletionPath = nil }.buttonStyle(.secondary)
                    Button(L("Move to Trash"), role: .destructive) { trashProject(path: path) }
                }
            }.padding(24).frame(width: 500).background(.surfaceFloating).cornerRadius(14).border(.border, width: 1)
        }
    }

    private func beginCreation(_ template: EditorProjectTemplate) {
        self.template = template
        projectName = template == .crystalRush ? "CrystalRush" : "NewGame"
        errorMessage = nil
    }

    private func open(path: String) {
        MainActor.assumeIsolated {
            errorMessage = nil
            do { try context.loadProject(directory: path) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func pickExistingProject() {
        MainActor.assumeIsolated {
            guard let display = context.display else { errorMessage = L("Folder picker is unavailable on this platform."); return }
            display.requestOpenFolder { path in
                if let path { self.open(path: path) }
            }
        }
    }

    private func pickParent() {
        MainActor.assumeIsolated {
            guard let display = context.display else { errorMessage = L("Folder picker is unavailable on this platform."); return }
            display.requestOpenFolder { path in
                if let path { self.parentPath = TextBuffer(path) }
            }
        }
    }

    private func createProject() {
        guard let template else { return }
        MainActor.assumeIsolated {
            errorMessage = nil
            do {
                try context.createProject(name: projectName.stringValue,
                                          parent: URL(fileURLWithPath: (parentPath.stringValue as NSString).expandingTildeInPath, isDirectory: true),
                                          template: template)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func trashProject(path: String) {
        do {
            _ = try EditorProjectLifecycle.moveToTrash(URL(fileURLWithPath: path))
            RecentProjectsStore.remove(path)
            recentProjects = RecentProjectsStore.all()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        deletionPath = nil
    }
}
