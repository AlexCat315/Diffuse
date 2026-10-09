import GuavaUIRuntime

public struct FormLayout {
    public var columns = 1
    public var horizontalLabels = false
    public var labelWidth: Float = 120
    public var spacing: Float = 18
    public init() {}
    mutating func validate() { columns = max(1, columns); labelWidth = max(0, labelWidth); spacing = max(0, spacing) }
}

public struct FormFieldPresentation {
    public var isRequired = false
    public var help = ""
    public var error: String?
    public var isVisible = true
    public init() {}
}

public struct FormField: Identifiable {
    public let id: String
    public let label: String
    public let content: AnyView
    public var presentation = FormFieldPresentation()
    public init<C: View>(_ id: String, _ label: String, configure: (inout FormFieldPresentation) -> Void = { _ in },
                         @ViewBuilder content: () -> C) {
        self.id = id; self.label = label; self.content = AnyView(content()); configure(&presentation)
    }
}

/// Layout and field descriptions; values, validation policy and submission remain application-owned.
public struct Form<Footer: View>: View {
    public let fields: [FormField]
    public let controller: FormController?
    public var layout = FormLayout()
    private let footer: Footer
    public init(_ fields: [FormField], controller: FormController? = nil,
                configure: (inout FormLayout) -> Void = { _ in }, @ViewBuilder footer: () -> Footer) {
        self.fields = fields; self.controller = controller; self.footer = footer()
        configure(&layout); layout.validate()
        precondition(Set(fields.map(\.id)).count == fields.count, "Form field IDs must be unique")
    }
    public var body: some View {
        let visible = fields.filter { $0.presentation.isVisible }
        Box(direction: .column, alignItems: .stretch, spacing: layout.spacing) {
            if let controller, !controller.issues.isEmpty {
                Alert("Please check the form", message: controller.issues.map { "\($0.label): \($0.message)" }.joined(separator: "\n"), tone: .danger)
            }
            for row in stride(from: 0, to: visible.count, by: layout.columns) {
                AnyView(Box(direction: .row, alignItems: .flexStart, spacing: layout.spacing) {
                    for field in visible[row..<min(visible.count, row + layout.columns)] {
                        AnyView(FormFieldView(field: field, layout: layout, error: controller?.error(for: field.id) ?? field.presentation.error)
                            .flex(1, shrink: 1, basis: 0).id(field.id))
                    }
                    for _ in 0..<max(0, layout.columns - min(layout.columns, visible.count - row)) {
                        AnyView(Box {}.flex(1, shrink: 1, basis: 0))
                    }
                })
            }
            Row(alignment: .center, spacing: 10) { Spacer(); footer }
        }
    }
}

public extension Form where Footer == EmptyView {
    init(_ fields: [FormField], controller: FormController? = nil, configure: (inout FormLayout) -> Void = { _ in }) {
        self.init(fields, controller: controller, configure: configure) { EmptyView() }
    }
}

private struct FormFieldView: View {
    let field: FormField
    let layout: FormLayout
    let error: String?
    var body: some View {
        Box(direction: layout.horizontalLabels ? .row : .column, alignItems: .stretch, spacing: 7) {
            FieldLabel(field.label) { $0.isRequired = field.presentation.isRequired; $0.targetID = field.id; $0.help = field.presentation.help }
                .frame(width: layout.horizontalLabels ? layout.labelWidth : nil)
                .flex(0, shrink: 0)
            Box(direction: .column, alignItems: .stretch, spacing: 5) {
                field.content.accessibility {
                    $0.label = field.label; $0.identifier = field.id
                    $0.state.isRequired = field.presentation.isRequired; $0.state.isInvalid = error != nil
                    $0.help = error ?? field.presentation.help
                }
                if let error { Text(error).font(.caption).foregroundColor(.error) }
                else if !field.presentation.help.isEmpty { Text(field.presentation.help).font(.caption).foregroundColor(.onSurfaceMuted) }
            }.flex(layout.horizontalLabels ? 1 : 0, shrink: 1)
        }.frame(minWidth: 0)
    }
}
