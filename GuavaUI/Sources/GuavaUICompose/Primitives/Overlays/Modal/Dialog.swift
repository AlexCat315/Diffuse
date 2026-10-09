import GuavaUIRuntime

public struct DialogOptions {
    public var modal = ModalOptions()
    public var description = ""
    public var showsCloseButton = true
    public init() {}
}

/// Structured modal header, scrollable content and a separate action area.
public struct Dialog<Content: View, Footer: View>: View {
    public let isPresented: Binding<Bool>
    public let title: String
    public var options = DialogOptions()
    private let content: Content
    private let footer: Footer
    public init(isPresented: Binding<Bool>, title: String, configure: (inout DialogOptions) -> Void = { _ in },
                @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.isPresented = isPresented; self.title = title; self.content = content(); self.footer = footer(); configure(&options)
    }
    public var body: some View {
        Modal(isPresented: isPresented, configure: { $0 = options.modal }) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Row(alignment: .center, spacing: 12) {
                    Column(alignment: .leading, spacing: 5) {
                        Text(title).font(.headline)
                        if !options.description.isEmpty { Text(options.description).font(.caption).foregroundColor(.onSurfaceMuted) }
                    }.flex(1, shrink: 1)
                    if options.showsCloseButton {
                        Button(icon: .resource(UICommonIcons.close), size: 14, tooltip: "Close dialog") { isPresented.wrappedValue = false }.buttonStyle(.ghost)
                    }
                }.padding(18).flex(0, shrink: 0)
                Divider()
                ScrollView(.vertical, scrollbarGutter: .stable) { content.padding(18).flex(0, shrink: 0) }.flex(1, shrink: 1, basis: 0).frame(minHeight: 0)
                Divider()
                Row(alignment: .center, spacing: 8) { Spacer(); footer }.padding(14).flex(0, shrink: 0)
            }.accessibility { $0.role = .dialog; $0.label = title; $0.help = options.description }
        }
    }
}
public extension Dialog where Footer == EmptyView {
    init(isPresented: Binding<Bool>, title: String, configure: (inout DialogOptions) -> Void = { _ in }, @ViewBuilder content: () -> Content) {
        self.init(isPresented: isPresented, title: title, configure: configure, content: content) { EmptyView() }
    }
}
public struct AlertDialogOptions {
    public var confirmTitle = "Confirm"
    public var cancelTitle = "Cancel"
    public var isDestructive = false
    public var isConfirming = false
    public var dismissAfterConfirm = true
    public init() {}
}
public struct AlertDialog: View {
    public let isPresented: Binding<Bool>
    public let title: String
    public let message: String
    public let onConfirm: () -> Void
    public var options = AlertDialogOptions()
    public init(isPresented: Binding<Bool>, title: String, message: String, configure: (inout AlertDialogOptions) -> Void = { _ in }, onConfirm: @escaping () -> Void) {
        self.isPresented = isPresented; self.title = title; self.message = message; self.onConfirm = onConfirm; configure(&options)
    }
    public var body: some View {
        Dialog(isPresented: isPresented, title: title, configure: {
            $0.modal.geometry.width = 420; $0.modal.geometry.height = 240
            $0.modal.dismissal.closesOnBackdrop = !options.isConfirming; $0.modal.dismissal.closesOnEscape = !options.isConfirming
            $0.showsCloseButton = false
        }, content: { Text(message).font(.body).foregroundColor(.onSurfaceVariant) }, footer: {
            Button(options.cancelTitle, isEnabled: !options.isConfirming) { isPresented.wrappedValue = false }.buttonStyle(.secondary)
            Button(options.confirmTitle, role: options.isDestructive ? .destructive : .normal, isLoading: options.isConfirming) {
                onConfirm(); if options.dismissAfterConfirm { isPresented.wrappedValue = false }
            }
        })
    }
}
public struct SheetOptions {
    public var edge: ModalPlacement = .trailing
    public var extent: Float = 400
    public var dismissal = ModalDismissal()
    public init() {}
}
public struct Sheet<Content: View>: View {
    public let isPresented: Binding<Bool>
    public var options = SheetOptions()
    private let content: Content
    public init(isPresented: Binding<Bool>, configure: (inout SheetOptions) -> Void = { _ in }, @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented; self.content = content(); configure(&options)
        options.extent = options.extent.isFinite ? max(64, options.extent) : 400
        if options.edge == .center { options.edge = .trailing }
    }
    public var body: some View {
        Modal(isPresented: isPresented, configure: {
            $0.geometry.placement = options.edge; $0.geometry.inset = 0; $0.geometry.cornerRadius = 0
            let horizontalEdge = options.edge == .top || options.edge == .bottom
            $0.geometry.width = horizontalEdge ? .greatestFiniteMagnitude : options.extent
            $0.geometry.height = horizontalEdge ? options.extent : .greatestFiniteMagnitude
            $0.dismissal = options.dismissal
        }) { content }
    }
}
