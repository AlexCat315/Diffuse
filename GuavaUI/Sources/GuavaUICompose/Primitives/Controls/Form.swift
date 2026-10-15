internal import Foundation
import GuavaUIRuntime

public struct FormLayout {
    public var columns = 1
    public var labelPlacement: FieldLabelPlacement = .adaptive
    public var labelWidth: Float = 120
    /// Preferred value-slot width used for column count and label reflow.
    /// Below this width a single stacked field fills the available width.
    public var minValueWidth: Float = 220
    public var spacing: Float = 18
    public init() {}
    mutating func validate() {
        columns = max(1, columns)
        labelWidth = labelWidth.isFinite ? max(0, labelWidth) : 120
        minValueWidth = minValueWidth.isFinite ? max(1, minValueWidth) : 220
        spacing = spacing.isFinite ? max(0, spacing) : 18
    }
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
    public init<C: View>(
        _ id: String, _ label: String, configure: (inout FormFieldPresentation) -> Void = { _ in },
        @ViewBuilder content: () -> C
    ) {
        self.id = id
        self.label = label
        self.content = AnyView(content())
        configure(&presentation)
    }
}

/// Layout and field descriptions; values, validation policy and submission remain application-owned.
public struct Form<Footer: View>: View {
    public let fields: [FormField]
    public let controller: FormController?
    public var layout = FormLayout()
    private let footer: Footer
    public init(
        _ fields: [FormField], controller: FormController? = nil,
        configure: (inout FormLayout) -> Void = { _ in }, @ViewBuilder footer: () -> Footer
    ) {
        self.fields = fields
        self.controller = controller
        self.footer = footer()
        configure(&layout)
        layout.validate()
        precondition(Set(fields.map(\.id)).count == fields.count, "Form field IDs must be unique")
    }
    public var body: some View {
        let visible = fields.filter { $0.presentation.isVisible }
        return FormLabelScope {
            ContainerSizeReader { size in
                let columns = min(
                    layout.columns,
                    max(1, Int((Float(size.width) + layout.spacing) / (layout.minValueWidth + layout.spacing))))
                Box(direction: .column, alignItems: .stretch, spacing: layout.spacing) {
                    if let controller, !controller.issues.isEmpty {
                        Alert(
                            "Please check the form",
                            message: controller.issues.map { "\($0.label): \($0.message)" }.joined(separator: "\n"),
                            tone: .danger)
                    }
                    Grid(
                        columns: Array(repeating: .flexible(), count: columns),
                        columnSpacing: CGFloat(layout.spacing), rowSpacing: CGFloat(layout.spacing)
                    ) {
                        for field in visible {
                            FormFieldView(
                                field: field, layout: layout,
                                error: controller?.error(for: field.id) ?? field.presentation.error
                            )
                            .id(field.id)
                        }
                    }
                    Box(direction: .row, alignItems: .center, justifyContent: .flexEnd, wrap: .wrap, spacing: 10) {
                        footer
                    }
                }
            }
        }
    }
}

extension Form where Footer == EmptyView {
    public init(
        _ fields: [FormField], controller: FormController? = nil, configure: (inout FormLayout) -> Void = { _ in }
    ) {
        self.init(fields, controller: controller, configure: configure) { EmptyView() }
    }
}

private struct FormFieldView: View {
    let field: FormField
    let layout: FormLayout
    let error: String?
    var body: some View {
        TextScalerReader { scaler in
            ContainerSizeReader { size in
                let labelWidth = scaler.scale(layout.labelWidth)
                let leading = layout.labelPlacement.isLeading(
                    width: Float(size.width), labelWidth: labelWidth,
                    minValueWidth: layout.minValueWidth, spacing: 7)
                Box(direction: leading ? .row : .column, alignItems: .stretch, spacing: 7) {
                    FieldLabel(field.label) {
                        $0.isRequired = field.presentation.isRequired
                        $0.targetID = field.id
                        $0.help = field.presentation.help
                    }
                    .frame(width: leading ? .points(labelWidth) : .auto)
                    .flex(0, shrink: 0)
                    .tooltip(field.label)
                    Box(direction: .column, alignItems: .stretch, spacing: 5) {
                        field.content.accessibility {
                            $0.label = field.label
                            $0.identifier = field.id
                            $0.state.isRequired = field.presentation.isRequired
                            $0.state.isInvalid = error != nil
                            $0.help = error ?? field.presentation.help
                        }
                        if let error {
                            Text(error).font(.caption).foregroundColor(.error)
                        } else if !field.presentation.help.isEmpty {
                            Text(field.presentation.help).font(.caption).foregroundColor(.onSurfaceMuted)
                        }
                    }.flex(leading ? 1 : 0, shrink: 1, basis: leading ? 0 : nil)
                }.frame(minWidth: 0)
            }
        }
    }
}
