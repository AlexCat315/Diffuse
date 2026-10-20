import GuavaUIRuntime

/// A fenced code block: authored lines in the mono face that scroll sideways
/// rather than wrap, under a header with the language and a copy action.
struct MarkdownCodeBlock: View {
    let language: String?
    let text: String
    @State private var copied = false

    var body: some View {
        Box(direction: .column, alignItems: .stretch) {
            Box(direction: .row, alignItems: .center, spacing: 8) {
                Text(language ?? "Code", lineLimit: 1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .flex(1, shrink: 1, basis: 0)
                Button(icon: .resource(copied ? UIIcons.Action.check : UIIcons.Action.copy), size: 14,
                       tooltip: copied ? "Copied" : "Copy code") {
                    ClipboardHolder.write?(text)
                    copied = true
                }
                .buttonStyle(.ghost)
                .controlSize(.small)
                DelayedReset(after: 1.6, isActive: copied) { copied = false }
            }
            .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 4))
            Divider()
            ScrollView(.horizontal, accessibilityLabel: language.map { "\($0) code" } ?? "Code") {
                codeText.padding(horizontal: 14, vertical: 12)
            }
        }
        .background(.surfaceSunken)
        .cornerRadius(10)
        .border(.border, width: 1)
        .clipped()
    }

    private var codeText: RichText {
        var code = RichText([RichTextRun(text)])
        code.role = .codeBlock
        return code
    }
}

/// Calls `reset` once `after` seconds have passed while `isActive`; used for
/// short-lived confirmations such as "Copied".
struct DelayedReset: _PrimitiveView {
    let after: Double
    let isActive: Bool
    let reset: () -> Void

    init(after: Double, isActive: Bool, reset: @escaping () -> Void) {
        self.after = after; self.isActive = isActive; self.reset = reset
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.addResource(DelayedResetClock())
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        node.firstResource(DelayedResetClock.self)?.configure(after: isActive ? after : nil, reset: reset)
    }
}

private final class DelayedResetClock: NodeResource, AnyAnimationController {
    private var remaining: Double = 0
    private var reset: () -> Void = {}
    var isFinished = true

    func mount(node: Node) {}
    func unmount(node: Node) { stop() }

    func configure(after: Double?, reset: @escaping () -> Void) {
        self.reset = reset
        guard let after else { stop(); return }
        guard isFinished else { return }
        remaining = after
        isFinished = false
        AnimatorScheduler.current.register(self)
    }

    func tick(deltaTime: Double) {
        guard !isFinished else { return }
        remaining -= deltaTime
        if remaining <= 0 { stop(); reset() }
    }

    private func stop() {
        guard !isFinished else { return }
        isFinished = true
        AnimatorScheduler.current.unregister(self)
    }
    func finishImmediately() { stop() }
    func cancel() { stop() }
}
