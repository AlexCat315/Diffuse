import EngineKernel
import Foundation
import GuavaUIRuntime

struct MenuItemRowHost: _PrimitiveView {
    let item: MenuRowPresentation
    let isHighlighted: Bool
    let showsSelectionColumn: Bool
    let submenu: AnyView?
    let events: MenuRowEvents
    let revealToken: Int

    private struct PaintIdentity: Equatable {
        let id: AnyHashable
        let isEnabled: Bool
        let isSelected: Bool
        let role: MenuItemRole
        let isHighlighted: Bool
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = true
        return node
    }

    func _updateNode(_ node: Node) {
        node.isFocusable = item.isEnabled
        node.isTabStop = item.isEnabled && isHighlighted
        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { focused in
            if focused { events.focus() }
        } as TextInputFocusChangeHandler
        if item.hasSubmenu && node.firstResource(PortalResource.self) == nil { node.addResource(PortalResource()) }
        synchronizeSubmenu(node)
        node.layoutDidUpdate = { node in
            if isHighlighted, node.attachments["__menu.revealToken"] as? Int != revealToken {
                node.attachments["__menu.revealToken"] = revealToken; events.reveal(node)
            }
            if submenu != nil && !Self.anchorIsVisible(node) { events.closeSubmenu() }
            node.firstResource(PortalResource.self)?.updatePosition(CGPoint(x: node.absoluteFrame.maxX, y: node.absoluteFrame.minY))
        }
        node.accessibility = AccessibilitySemantics(.button) { $0.label = item.title; $0.help = item.shortcut ?? ""; $0.state.isEnabled = item.isEnabled; $0.state.isSelected = item.isSelected; $0.combinesChildren = true; $0.state.isExpanded = item.hasSubmenu ? submenu != nil : nil }
        node.accessibilityActions = AccessibilityActions()
        if item.isEnabled { node.accessibilityActions.activate = { events.activate(node) } }

        node.attachments[Self.itemIDKey] = item.id
        if item.isEnabled {
            if node.attachments[Self.hoveredKey] == nil {
                node.attachments[Self.hoveredKey] = false
            }
            if node.attachments[Self.pressedKey] == nil {
                node.attachments[Self.pressedKey] = false
            }
        } else {
            if FocusChainHolder.current?.focused === node { FocusChainHolder.current?.focus(nil) }
            node.attachments[Self.hoveredKey] = false
            node.attachments[Self.pressedKey] = false
            node.attachments.removeValue(forKey: Self.activePressKey)
            if PointerCaptureHolder.current?.target === node {
                PointerCaptureHolder.current?.release()
            }
        }
        node.cursor = item.isEnabled ? .pointer : .notAllowed
        node.attachments["__menu_highlighted"] = isHighlighted
        node.attachments["__menu_enabled"] = item.isEnabled
        updateMenuItemFill(node)
        node.updateDraw(identity: PaintIdentity(id: item.id,
                                                isEnabled: item.isEnabled,
                                                isSelected: item.isSelected,
                                                role: item.role,
                                                isHighlighted: isHighlighted)) { [weak node] list, origin in
            guard let node,
                  let background = node.attachments["__menu_visual_fill"] as? Color else {
                return
            }
            let width = max(0, Float(node.frame.width) - 8)
            let rect = UIRect(x: Float(origin.x) + 4,
                              y: Float(origin.y) + 2,
                              width: width,
                              height: 28)
            list.addRoundedRect(rect,
                                radius: 5,
                                color: background.multipliedAlpha(node.opacity))
        }

        guard item.isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }

        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                setMenuItemInteraction(node, key: Self.hoveredKey, value: true)
                events.hover(node, true)
            case .leave:
                events.hover(node, false)
                node.attachments.removeValue(forKey: Self.activePressKey)
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                setMenuItemInteraction(node, key: Self.hoveredKey, value: false)
                setMenuItemInteraction(node, key: Self.pressedKey, value: false)
            }
        }
        registry.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                node.attachments[Self.activePressKey] = true
                PointerCaptureHolder.current?.acquire(node)
                setMenuItemInteraction(node, key: Self.pressedKey, value: true)
                return .handled
            case .up:
                let wasActive = node.attachments[Self.activePressKey] as? Bool == true
                node.attachments.removeValue(forKey: Self.activePressKey)
                setMenuItemInteraction(node, key: Self.pressedKey, value: false)
                defer {
                    if PointerCaptureHolder.current?.target === node {
                        PointerCaptureHolder.current?.release()
                    }
                }
                guard wasActive else { return .ignored }
                guard node.absoluteFrame.contains(CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))) else { return .handled }
                events.activate(node)
                return .handled
            }
        }
        registry.setKey(node) { event, _ in
            switch event.scancode {
            case Scancode.return, Scancode.space, Scancode.keypadEnter:
                if !event.isRepeat { events.activate(node) }
                return .handled
            default:
                return .ignored
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.height = 32
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.height = 32
    }

    func _children(for node: Node) -> [any View] {
        let theme = node.theme
        let titleColor: Color = !item.isEnabled
            ? (theme.textEmphasis.disabled ?? theme.colors.onSurfaceMuted)
            : item.role == .destructive ? theme.colors.error : theme.colors.onSurface
        let textOpacity: Float = 1

        let checkmarkSize: Float = 10
        let row = Row(alignment: .center, spacing: 8) {
            if showsSelectionColumn {
                // Fixed-width slot — a grow-able Spacer here pushes every
                // unchecked title toward the centre of the menu.
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    if item.isSelected {
                        Icon(UICommonIcons.checkmark, size: checkmarkSize, color: titleColor)
                            .opacity(textOpacity)
                    }
                }
                .frame(width: checkmarkSize)
            }
            Text(item.title)
                .lineLimit(1)
                .font(.body)
                .foregroundColor(titleColor)
                .opacity(textOpacity)
                .clipped()
                .flex()
            if item.hasSubmenu {
                Icon(UICommonIcons.chevronRight, size: 12, color: titleColor)
            } else if let shortcut = item.shortcut {
                Text(shortcut)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(theme.colors.onSurfaceMuted)
                    .opacity(textOpacity)
                    .clipped()
            }
        }
        .padding(horizontal: 16, vertical: 2)
        .frame(height: 32)

        return [row]
    }

    private func synchronizeSubmenu(_ node: Node) {
        guard let resource = node.firstResource(PortalResource.self) else { return }
        guard let submenu, item.isEnabled else { resource.unmount(node: node); return }
        resource.present(in: node.compositionValue(of: PortalStoreEnvironment.key),
            position: CGPoint(x: node.absoluteFrame.maxX, y: node.absoluteFrame.minY), width: nil,
            content: AnyView(submenu.theme(node.theme)), placement: .besideAnchor)
        resource.setDismissal(anchor: { [weak node] in node?.absoluteFrame ?? .zero }, dismiss: events.closeSubmenu)
    }
    private static func anchorIsVisible(_ node: Node) -> Bool {
        var visible = node.absoluteFrame, ancestor = node.parent
        while let candidate = ancestor {
            if candidate.clipsToBounds { visible = visible.intersection(candidate.absoluteFrame) }
            if visible.isNull || visible.width <= 0 || visible.height <= 0 { return false }
            ancestor = candidate.parent
        }
        return true
    }

    private static let hoveredKey = "__menu_item_hovered"
    private static let itemIDKey = "__menu_item_id"
    private static let pressedKey = "__menu_item_pressed"
    private static let activePressKey = "__menu_item_active_press"
}

private func updateMenuItemFill(_ node: Node) {
    let enabled = node.attachments["__menu_enabled"] as? Bool == true
    let pressed = node.attachments["__menu_item_pressed"] as? Bool == true
    let hovered = node.attachments["__menu_item_hovered"] as? Bool == true
    let highlighted = node.attachments["__menu_highlighted"] as? Bool == true
    let colors = node.theme.colors
    let fill = !enabled ? Color.clear : pressed ? colors.stateLayerPressed
        : hovered ? colors.stateLayerHover : highlighted ? colors.stateLayerSelected : .clear
    let previous = node.attachments["__menu_visual_fill"] as? Color
    let apply = { [node] in
        node.animatableSet(propertyKey: "menu.fill", current: previous ?? fill, to: fill) { [weak node] color in
            node?.attachments["__menu_visual_fill"] = color
            node?.markRenderDirty(reason: .styleSet(field: "menu.fill"))
        }
    }
    if previous != nil { withAnimation(.semantic(.fast, in: node.theme), apply) } else { apply() }
}

private func setMenuItemInteraction(_ node: Node, key: String, value: Bool) {
    if node.attachments[key] as? Bool == value {
        return
    }
    node.attachments[key] = value
    updateMenuItemFill(node)
    node.markRenderDirty(reason: .styleSet(field: key))
}
