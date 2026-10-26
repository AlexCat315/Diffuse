import EditorCore
import Foundation
import MediaRuntime
import CoveUI
import CoveUIRuntime

struct MediaTimelinePanel: View {
    let model: EditorMediaWorkspace
    let projectRoot: URL
    private var observed: Observed<EditorMediaWorkspace, MediaComposition>
    @State private var path: TextBuffer = ""
    @State private var start: TextBuffer = "0"
    @State private var duration: TextBuffer = "1"
    @State private var offset: TextBuffer = "0"
    @State private var selected = 0
    @State private var image: ImageAssetRegistry.Asset?
    @State private var status = ""
    @State private var isExporting = false
    @State private var previewGeneration = UUID()
    @State private var playback: Task<Void, Never>?

    init(model: EditorMediaWorkspace, projectRoot: URL) {
        self.model = model; self.projectRoot = projectRoot
        observed = Observed(\.composition, on: model)
    }
    var body: some View {
        let composition = observed.wrappedValue
        Column(alignment: .leading, spacing: 8) {
            Row(spacing: 6) {
                TextField("Project video path", text: $path).flex()
                Button(L("Add Clip")) { perform { try model.add(path.stringValue) } }
                Button(L("Save")) { status = model.save() ? L("Saved") : (model.error ?? "") }
                Button(isExporting ? L("Exporting…") : L("Export MP4"), isEnabled: !isExporting && !composition.clips.isEmpty) { export() }
            }
            SurfaceReader { surface in
                if let image {
                    Image(source: .asset(image), width: min(640, max(100, surface.viewport.width - 80)), height: 260, contentMode: .fit)
                } else { Text(L("Select a clip and preview a frame.")).foregroundColor(.onSurfaceMuted).frame(height: 120) }
            }
            Text(String(format: "%.2f s · %d clips%@", composition.duration, composition.clips.count, model.isDirty ? " •" : "")).font(.label)
            ScrollView {
                Column(alignment: .leading, spacing: 4) {
                    for (index, clip) in composition.clips.enumerated() {
                        AnyView(Row(spacing: 4) {
                            Button("\(index + 1). \(clip.source) [\(String(format: "%.2f", clip.start)) + \(String(format: "%.2f", clip.duration)) s]", isSelected: selected == index) {
                                selected = index; start = TextBuffer(String(clip.start)); duration = TextBuffer(String(clip.duration))
                                preview()
                            }.buttonStyle(.secondary).flex()
                            Button("↑") { model.move(index, by: -1) }.buttonStyle(.ghost)
                            Button("↓") { model.move(index, by: 1) }.buttonStyle(.ghost)
                            Button(L("Remove")) { model.remove(index); image = nil }.buttonStyle(.ghost)
                        })
                    }
                }
            }.flex().frame(minHeight: 0)
            Row(spacing: 6) {
                Text(L("In")); TextField("0", text: $start).frame(width: 80)
                Text(L("Duration")); TextField("1", text: $duration).frame(width: 80)
                Button(L("Trim")) {
                    perform {
                        guard let start = Double(start.stringValue), let duration = Double(duration.stringValue) else { throw MediaError.invalid("Enter seconds as numbers") }
                        try model.trim(selected, start: start, duration: duration)
                    }
                }
                TextField("Preview offset (s)", text: $offset).frame(width: 130)
                Button(L("Preview")) { preview() }
                Button(L("Play")) { play() }
                Button(L("Stop")) { playback?.cancel(); playback = nil }
            }
            Text(status).font(.caption).foregroundColor(.onSurfaceVariant)
        }.padding(8).frame(minWidth: 0, minHeight: 0)
            .modifier(PlaybackLifetime(task: $playback))
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); status = "" } catch { status = error.localizedDescription }
    }
    private func preview() {
        playback?.cancel(); playback = nil
        let model = model, selected = selected, seconds = Double(offset.stringValue) ?? 0
        let image = $image, status = $status, generation = $previewGeneration
        let request = UUID(); generation.wrappedValue = request
        Task { @MainActor in
            do {
                if let frame = try await model.preview(selected, at: seconds) {
                    guard generation.wrappedValue == request else { return }
                    image.wrappedValue = try ImageAssetRegistry.Asset(image: DecodedImage(pixels: Array(frame.rgba), width: frame.width, height: frame.height))
                    status.wrappedValue = String(format: "Frame %.3f s", frame.time)
                } else if generation.wrappedValue == request { image.wrappedValue = nil; status.wrappedValue = L("End of video") }
            } catch { if generation.wrappedValue == request { status.wrappedValue = error.localizedDescription } }
        }
    }
    private func play() {
        playback?.cancel()
        guard model.composition.clips.indices.contains(selected) else { return }
        let model = model, selected = selected
        let image = $image, status = $status, generation = $previewGeneration
        let request = UUID(); generation.wrappedValue = request
        playback = Task { @MainActor in
            do {
                try await model.play(selected) { frame in
                    await MainActor.run {
                        guard generation.wrappedValue == request else { return }
                        image.wrappedValue = try? ImageAssetRegistry.Asset(image: DecodedImage(pixels: Array(frame.rgba), width: frame.width, height: frame.height))
                        status.wrappedValue = String(format: "%.3f s", frame.time)
                    }
                }
            } catch is CancellationError {} catch { status.wrappedValue = error.localizedDescription }
        }
    }

    private func export() {
        isExporting = true
        let model = model, projectRoot = projectRoot, exporting = $isExporting, status = $status
        Task { @MainActor in
            defer { exporting.wrappedValue = false }
            do {
                let directory = projectRoot.appendingPathComponent("Exports")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appendingPathComponent("video-\(UUID().uuidString).mp4")
                try await model.export(to: output, executable: FFmpegTools.executable())
                status.wrappedValue = output.path
            } catch { status.wrappedValue = error.localizedDescription }
        }
    }
}

private struct PlaybackLifetime: ViewModifier {
    let task: Binding<Task<Void, Never>?>
    func apply(node: Node) {
        if node.firstResource(PlaybackCleanup.self) == nil { node.addResource(PlaybackCleanup(task: task)) }
    }
}
private final class PlaybackCleanup: NodeResource {
    private let task: Binding<Task<Void, Never>?>
    init(task: Binding<Task<Void, Never>?>) { self.task = task }
    func mount(node: Node) {}
    func unmount(node: Node) { task.wrappedValue?.cancel(); task.wrappedValue = nil }
}
