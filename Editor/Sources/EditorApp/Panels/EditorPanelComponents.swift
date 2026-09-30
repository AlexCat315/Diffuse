import GuavaUICompose
import GuavaUIRuntime

/// Shared editor-panel chrome. Keeping the density, insets, and surface in one
/// place makes docked panels feel like parts of one application instead of a
/// collection of unrelated tools.
struct EditorPanelToolbar<Content: View>: View {
    let content: Content
    let spacing: Float

    init(spacing: Float = 8, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.spacing = spacing
    }

    var body: some View {
        Row(alignment: .center, spacing: spacing) {
            content
        }
        .padding(horizontal: 8, vertical: 3)
        .frame(minHeight: 30)
        .background(.surface)
    }
}

/// Standard search row used by panels with filterable content. The optional
/// summary gives immediate feedback (for example, "8 / 42") without taking
/// focus away from the query.
struct EditorPanelSearchBar: View {
    let placeholder: String
    let text: Binding<String>
    let summary: String?
    let onSubmit: (() -> Void)?
    let onCancel: (() -> Void)?
    let actions: AnyView

    init<ActionContent: View>(_ placeholder: String,
                              text: Binding<String>,
                              summary: String? = nil,
                              onSubmit: (() -> Void)? = nil,
                              onCancel: (() -> Void)? = nil,
                              @ViewBuilder actions: () -> ActionContent) {
        self.placeholder = placeholder
        self.text = text
        self.summary = summary
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.actions = AnyView(actions())
    }

    init(_ placeholder: String,
         text: Binding<String>,
         summary: String? = nil,
         onSubmit: (() -> Void)? = nil,
         onCancel: (() -> Void)? = nil) {
        self.init(placeholder,
                  text: text,
                  summary: summary,
                  onSubmit: onSubmit,
                  onCancel: onCancel) {
            EmptyView()
        }
    }

    var body: some View {
        Row(alignment: .center, spacing: 6) {
            TextField(placeholder,
                      text: text,
                      size: .small,
                      clearable: true,
                      onSubmit: onSubmit,
                      onCancel: onCancel)
                .font(.caption)
                .flex()

            if let summary, !summary.isEmpty {
                EditorPanelBadge(summary)
            }

            actions
        }
        .padding(horizontal: 8, vertical: 5)
        .background(.surface)
    }
}

/// Compact count/status chip for toolbars and filter rows.
struct EditorPanelBadge: View {
    let text: String
    let foreground: SemanticColorRef

    init(_ text: String, foreground: SemanticColorRef = .onSurfaceVariant) {
        self.text = text
        self.foreground = foreground
    }

    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            Text(text, lineLimit: 1)
                .font(.caption)
                .foregroundColor(foreground)
        }
        .padding(horizontal: 5, vertical: 1)
        .background(.surfaceVariant)
        .cornerRadius(4)
    }
}

/// Empty and zero-result state shared by editor panels.
struct EditorPanelEmptyState: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        Box(direction: .column,
            alignItems: .center,
            justifyContent: .center,
            spacing: 6) {
            Text(title)
                .font(.bodyStrong)
                .foregroundColor(.onSurface)

            if let detail, !detail.isEmpty {
                Text(detail, alignment: .center)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .frame(maxWidth: 280)
            }
        }
        .padding(horizontal: 16, vertical: 16)
    }
}

/// Reusable icon-only action used by compact panel toolbars.
struct EditorPanelIconButton: View {
    let icon: BundleImageResource
    let tooltip: String
    let isEnabled: Bool
    let action: () -> Void

    init(_ icon: BundleImageResource,
         tooltip: String,
         isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.icon = icon
        self.tooltip = tooltip
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(icon: .resource(icon),
               size: 11,
               isEnabled: isEnabled,
               tooltip: tooltip,
               action: action)
            .buttonStyle(ToggleButtonStyle(height: 22))
    }
}
