import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose
@testable import GuavaUITerminal

/// Mounts `TerminalView` in a real view graph and drives it through the
/// production event dispatcher. Programs run on a real PTY; their output is
/// applied through a stand-in UI work queue that `pump` drains.
@Suite("Terminal view", .serialized)
@MainActor
struct ViewTests {
    /// Process-wide holders (text environment, input context, clipboard) are
    /// shared with every other UI suite in the process.
    private static let lock = NSLock()

    private final class Harness {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        let context = PlatformInputContext()
        let session: TerminalSession
        lazy var dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                              capture: context.pointerCapture, focusChain: context.focusChain)
        var openedLinks: [URL] = []
        /// Stand-in for the host's UI work queue (`UIWorkSchedulerHolder`).
        let work = WorkQueue()

        init(_ command: TerminalCommand) {
            let work = work
            session = TerminalSession(command: command, scrollbackLines: 100) { work.enqueue($0) }
        }

        var surface: Node { Self.nodes(graph.tree.root!).first { $0.isFocusable && $0.draw != nil }! }
        var metrics: CellMetrics { surface.firstResource(SurfaceState.self)!.metrics! }

        func mount<V: View>(_ view: V, width: Float, height: Float) {
            context.withCurrent {
                graph.install(root: view)
                layout(width: width, height: height)
            }
        }

        /// Lays out and paints, as one host frame does.
        func layout(width: Float, height: Float) {
            context.withCurrent {
                for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: height) }
                surface.draw?(DrawList(), .zero)
            }
        }

        func send(_ event: InputEvent) { context.withCurrent { dispatcher.dispatch(event) } }

        /// Window point at the centre of a grid cell.
        func point(_ column: Int, _ row: Int, inset: Float = 0.5) -> (x: Float, y: Float) {
            let origin = surface.absoluteOrigin
            return (Float(origin.x) + (Float(column) + inset) * metrics.width,
                    Float(origin.y) + (Float(row) + 0.5) * metrics.height)
        }

        func click(_ column: Int, _ row: Int, modifiers: KeyModifiers = [], button: MouseButton = .left) {
            let at = point(column, row)
            send(.mouseButtonDown(.init(button: button, x: at.x, y: at.y, clicks: 1, modifiers: modifiers)))
            send(.mouseButtonUp(.init(button: button, x: at.x, y: at.y, clicks: 1, modifiers: modifiers)))
        }

        func key(_ scancode: UInt32, _ modifiers: KeyModifiers = []) {
            send(.keyDown(.init(scancode: scancode, keycode: 0, modifiers: modifiers, isRepeat: false)))
        }

        var screen: String {
            let frame = session.frame
            return (0..<frame.rows).map { frame.text(ofRow: $0) }.joined(separator: "\n")
        }

        func pump(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline {
                if !work.drain() { Thread.sleep(forTimeInterval: 0.005) }
            }
            if !condition() { Issue.record("timed out; screen:\n\(screen)") }
        }

        func tearDown() {
            session.terminate()
            context.withCurrent { graph.install(root: EmptyView()) }
        }

        static func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
    }

    private static func environment() -> TextEnvironment {
        let path = ["/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Monaco.ttf",
                    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                    "/usr/share/fonts/TTF/DejaVuSansMono.ttf"].first { FileManager.default.fileExists(atPath: $0) } ?? ""
        let atlas = FontAtlas(width: 512, height: 512)
        atlas.loadFont(path: path, size: 13)
        let shaper = TextShaper()
        if let face = atlas.freetypeFace { shaper.setFont(ftFace: face, size: 13) }
        return TextEnvironment(atlas: atlas, shaper: shaper, atlasTextureID: 1, defaultLineHeight: 17,
                               defaultColor: .white, defaultFont: .monospaced(size: 13),
                               fontResolver: TextFontResolver(primaryFontName: "Menlo", atlas: atlas))
    }

    private func withHarness(_ command: TerminalCommand = TerminalCommand(executable: "/bin/cat"),
                             _ body: (Harness) throws -> Void) rethrows {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = Self.environment()
        defer { TextEnvironmentHolder.current = previous }
        let harness = Harness(command)
        let previousScheduler = UIWorkSchedulerHolder.enqueue
        UIWorkSchedulerHolder.enqueue = harness.work.enqueue
        defer { harness.tearDown(); UIWorkSchedulerHolder.enqueue = previousScheduler }
        try body(harness)
    }

    @Test("Mounting starts the program, output repaints, a click focuses")
    func mountAndDraw() {
        withHarness(TerminalCommand(executable: "/bin/sleep", arguments: ["30"])) { harness in
            harness.mount(TerminalView(session: harness.session).frame(width: 400, height: 200), width: 400, height: 200)
            #expect(harness.session.status == .running)
            let expected = harness.metrics.grid(width: 400, height: 200)
            #expect(harness.session.frame.columns == expected.columns && harness.session.frame.rows == expected.rows)

            harness.graph.tree.flush()
            #expect(!harness.surface.renderDirty)
            harness.session.feed(Array("\u{1B}[31mred\u{1B}[0m".utf8))
            #expect(harness.surface.renderDirty)

            harness.click(3, 3)
            #expect(harness.context.focusChain.focused === harness.surface)
        }
    }

    @Test("Inside a stack without a frame the grid fills the width and follows resizes")
    func fillsAndResizes() {
        withHarness(TerminalCommand(executable: "/bin/sh", arguments: ["-c", "stty size; read _; stty size; sleep 30"])) { harness in
            harness.mount(Column(spacing: 0) {
                Text("Title")
                TerminalView(session: harness.session)
            }.framePercent(width: 100, height: 100), width: 400, height: 200)
            let small = harness.metrics.grid(width: Float(harness.surface.frame.width), height: Float(harness.surface.frame.height))
            #expect(harness.surface.frame.width == 400)
            #expect(small.columns > 40)
            #expect(harness.session.frame.columns == small.columns)
            harness.pump { harness.screen.contains("\(small.rows) \(small.columns)") }

            harness.layout(width: 700, height: 420)
            let large = harness.metrics.grid(width: Float(harness.surface.frame.width), height: Float(harness.surface.frame.height))
            #expect(large.columns > small.columns && large.rows > small.rows)
            #expect(harness.session.frame.columns == large.columns && harness.session.frame.rows == large.rows)
            harness.session.send("\r")
            harness.pump { harness.screen.contains("\(large.rows) \(large.columns)") }
        }
    }

    @Test("Keys typed during IME composition stay with the input method")
    func imeComposition() {
        withHarness { harness in
            harness.mount(TerminalView(session: harness.session), width: 400, height: 200)
            harness.click(0, 0)
            harness.send(.textEditing(.init(text: "ni", start: 2, length: 0)))
            harness.key(42)  // Backspace edits the composition
            harness.key(40)  // Return picks the candidate
            harness.send(.textEditing(.init(text: "", start: 0, length: 0)))
            harness.send(.textInput("你"))
            harness.key(40)
            harness.pump { harness.screen.components(separatedBy: "你").count == 3 }
            #expect(harness.screen.hasPrefix("你\n你"))
        }
    }

    @Test("Drag selects, ⌘C copies, typing clears the selection")
    func selectionAndCopy() {
        withHarness { harness in
            harness.mount(TerminalView(session: harness.session), width: 400, height: 200)
            harness.session.feed(Array("hello world\r\n".utf8))
            var copied: String?
            let previousWrite = ClipboardHolder.write
            ClipboardHolder.write = { copied = $0 }
            defer { ClipboardHolder.write = previousWrite }

            let start = harness.point(0, 0, inset: 0.1), end = harness.point(4, 0, inset: 0.9)
            harness.send(.mouseButtonDown(.init(button: .left, x: start.x, y: start.y, clicks: 1)))
            harness.send(.mouseMotion(.init(x: end.x, y: end.y, deltaX: 0, deltaY: 0)))
            harness.send(.mouseButtonUp(.init(button: .left, x: end.x, y: end.y, clicks: 1)))
            #expect(harness.session.frame[0, 0].isSelected && harness.session.frame[0, 4].isSelected)
            harness.key(6, .lgui)
            #expect(copied == "hello")

            harness.send(.textInput("x"))
            #expect(!harness.session.frame[0, 0].isSelected)
        }
    }

    @Test("Mouse reports reach programs that track the mouse; Shift still selects")
    func mouseReporting() {
        withHarness(TerminalCommand(executable: "/bin/sh", arguments: ["-c", "stty -echo -icanon; cat -v"])) { harness in
            harness.mount(TerminalView(session: harness.session), width: 400, height: 200)
            harness.session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
            harness.click(4, 2)
            harness.pump { harness.screen.contains("^[[<0;5;3M^[[<0;5;3m") }
            harness.click(4, 2, modifiers: .lshift)
            #expect(!harness.screen.contains("^[[<4;"))
        }
    }

    @Test("⌘-click opens hyperlinks through onOpenLink; hovering shows a pointer")
    func hyperlinks() {
        withHarness(TerminalCommand(executable: "/bin/sleep", arguments: ["30"])) { harness in
            harness.mount(TerminalView(session: harness.session) { harness.openedLinks.append($0) }, width: 400, height: 200)
            harness.session.feed(Array("go \u{1B}]8;;https://example.com/x\u{1B}\\here\u{1B}]8;;\u{1B}\\ \u{1B}]8;;javascript:alert(1)\u{1B}\\bad\u{1B}]8;;\u{1B}\\".utf8))
            harness.layout(width: 400, height: 200)

            let link = harness.point(4, 0)
            harness.send(.mouseMotion(.init(x: link.x, y: link.y, deltaX: 0, deltaY: 0)))
            #expect(harness.surface.cursor == .pointer)
            let text = harness.point(1, 0)
            harness.send(.mouseMotion(.init(x: text.x, y: text.y, deltaX: 0, deltaY: 0)))
            #expect(harness.surface.cursor == .ibeam)

            harness.click(4, 0)
            #expect(harness.openedLinks.isEmpty)
            harness.click(4, 0, modifiers: .lgui)
            #expect(harness.openedLinks == [URL(string: "https://example.com/x")!])
            harness.click(9, 0, modifiers: .lgui)
            #expect(harness.openedLinks.count == 1)
        }
    }

    @Test("The cursor blinks only while focused")
    func blink() {
        withHarness(TerminalCommand(executable: "/bin/sleep", arguments: ["30"])) { harness in
            harness.mount(TerminalView(session: harness.session), width: 400, height: 200)
            let blink = harness.surface.firstResource(SurfaceState.self)!.blink
            harness.layout(width: 400, height: 200)
            harness.pump { true }
            #expect(blink.isVisible)
            harness.click(0, 0)
            harness.layout(width: 400, height: 200)
            harness.pump { !blink.isVisible }
            harness.pump { blink.isVisible }
            harness.context.withCurrent { harness.context.focusChain.clear() }
            harness.layout(width: 400, height: 200)
            #expect(blink.isVisible)
        }
    }
}

/// Thread-safe FIFO of UI work, drained by the test on its own thread.
final class WorkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [() -> Void] = []

    func enqueue(_ work: @escaping () -> Void) { lock.withLock { items.append(work) } }

    /// Runs everything queued so far; returns whether anything ran.
    func drain() -> Bool {
        let batch = lock.withLock { () -> [() -> Void] in defer { items.removeAll() }; return items }
        batch.forEach { $0() }
        return !batch.isEmpty
    }
}
