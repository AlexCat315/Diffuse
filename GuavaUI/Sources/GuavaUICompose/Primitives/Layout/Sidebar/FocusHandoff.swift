private import GuavaUIRuntime

/// Tracks focus at the shell boundary before retained slots change visibility.
/// Node references never escape the component or enter the caller's session.
final class SidebarFocusHandoff {
  weak var navigation: Node?
  weak var trigger: Node?
  private weak var previous: Node?
  private weak var chain: FocusChain?
  private var mode: SidebarMode?
  private var destination: Destination?
  private var visible = true
  private var isModal = false
  private enum Destination { case trigger, navigation }

  func prepare(mode next: SidebarMode, isModal: Bool, chain: FocusChain?) {
    self.chain = chain
    defer {
      mode = next
      self.isModal = isModal
    }
    guard mode != nil, mode != next, let chain, let focused = chain.focused else { return }
    if contains(focused, in: navigation) {
      destination = next == .compact && !isModal ? .trigger : .navigation
    } else if contains(focused, in: trigger), next != .compact {
      destination = .navigation
    } else {
      return
    }
    previous = focused
    visible = chain.isFocusVisible
  }

  func focusOpener(label: String) {
    guard let chain else { return }
    for root in [trigger, navigation].compactMap({ $0 }) {
      if let opener = focusables(in: root).first(where: { $0.accessibility?.label == label }) {
        chain.focus(opener, visible: chain.isFocusVisible)
        return
      }
    }
  }

  func complete(chain: FocusChain?) {
    guard let chain else { return }
    // A slot's own container query can settle one composition after the shell.
    // Hand off only if the remembered focus actually became inactive.
    if destination == nil, chain.focused == nil, let previous, !previous.acceptsSubtreeInput {
      if contains(previous, in: navigation) {
        destination = mode == .compact && !isModal ? .trigger : .navigation
      } else if contains(previous, in: trigger), mode != .compact {
        destination = .navigation
      }
    }
    defer {
      destination = nil
      if let focused = chain.focused {
        previous =
          contains(focused, in: navigation) || contains(focused, in: trigger) ? focused : nil
        visible = chain.isFocusVisible
      }
    }
    guard let destination else { return }
    switch destination {
    case .trigger:
      if let trigger, let target = focusables(in: trigger).first {
        chain.focus(target, visible: visible)
      }
    case .navigation:
      guard let navigation else { return }
      if let previous, contains(previous, in: navigation), previous.isFocusable,
        previous.acceptsSubtreeInput
      {
        chain.focus(previous, visible: visible)
      } else {
        let candidates = focusables(in: navigation)
        if let target = candidates.first(where: { $0.accessibility?.state.isSelected == true })
          ?? candidates.first
        {
          chain.focus(target, visible: visible)
        }
      }
    }
  }

  private func contains(_ candidate: Node, in root: Node?) -> Bool {
    guard let root else { return false }
    var current: Node? = candidate
    while let node = current {
      if node === root { return true }
      current = node.parent
    }
    return false
  }
  private func focusables(in root: Node) -> [Node] {
    var pending = [root]
    var result: [Node] = []
    while let node = pending.popLast() {
      guard node.acceptsSubtreeInput else { continue }
      if node.isFocusable && node !== root { result.append(node) }
      pending.append(contentsOf: node.children.reversed())
    }
    return result
  }
}
