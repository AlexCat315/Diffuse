public import GuavaUIRuntime

/// An anchored question with explicit Cancel and Confirm actions.
public struct Popconfirm: View {
  private let triggerTitle: String
  private let icon: BundleImageResource?
  private let question: PopconfirmQuestion
  private let placement: PopoverPlacement
  private let isEnabled: Bool
  private let onConfirm: () -> Void
  @State private var isPresented = false

  public init(_ triggerTitle: String, icon: BundleImageResource? = nil,
              title: String, message: String = "", confirmTitle: String = "Confirm",
              cancelTitle: String = "Cancel", role: ButtonRole = .normal,
              placement: PopoverPlacement = .bottom, isEnabled: Bool = true,
              onConfirm: @escaping () -> Void) {
    self.triggerTitle = triggerTitle; self.icon = icon
    question = PopconfirmQuestion(title: title, message: message, confirmTitle: confirmTitle,
                                  cancelTitle: cancelTitle, role: role)
    self.placement = placement; self.isEnabled = isEnabled; self.onConfirm = onConfirm
  }
  public var body: some View {
    if !isEnabled && isPresented { isPresented = false }
    var popover = Popover(isPresented: $isPresented, isEnabled: isEnabled, width: 300,
                         placement: placement, surface: .bubble, overflow: .constrain,
                         triggerStyle: AnyButtonStyle(SecondaryButtonStyle()), label: {
        Row(alignment: .center, spacing: 6) {
          if let icon { Icon(icon, size: .small, color: question.role == .destructive ? .error : .onSurfaceVariant).accessibilityHidden() }
          Text(triggerTitle).font(.label).foregroundColor(question.role == .destructive ? .error : .onSurface)
        }
      }, content: {
        PopconfirmContent(question: question, onCancel: { isPresented = false }, onConfirm: {
          guard isPresented && isEnabled else { return }
          isPresented = false
          onConfirm()
        }).accessibility { $0.role = .dialog; $0.label = question.title }
      })
    popover.triggerDescription = PopoverTriggerDescription(label: triggerTitle)
    return popover.debugName("popconfirm-trigger-\(triggerTitle)")
  }
}

struct PopconfirmQuestion {
  let title: String
  let message: String
  let confirmTitle: String
  let cancelTitle: String
  let role: ButtonRole
}

private struct PopconfirmContent: View {
  let question: PopconfirmQuestion
  let onCancel: () -> Void
  let onConfirm: () -> Void
  var body: some View {
    Box(direction: .column, alignItems: .stretch, spacing: 10) {
      Text(question.title).font(.bodyStrong).accessibility { $0.role = .heading }
      if !question.message.isEmpty { Text(question.message).foregroundColor(.onSurfaceVariant) }
      Box(direction: .row, alignItems: .center, justifyContent: .flexEnd, wrap: .wrap, spacing: 8) {
        Button(role: .cancel, action: onCancel) { Text(question.cancelTitle).font(.label) }.buttonStyle(.secondary)
          .compositionLocal(ActionControlAccessibility.label, question.cancelTitle)
        Button(role: question.role, action: onConfirm) { Text(question.confirmTitle).font(.label) }
          .buttonStyle(question.role == .destructive ? AnyButtonStyle(DestructiveButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
          .compositionLocal(ActionControlAccessibility.label, question.confirmTitle)
      }.frame(minWidth: 0)
    }.frame(minWidth: 0)
  }
}
