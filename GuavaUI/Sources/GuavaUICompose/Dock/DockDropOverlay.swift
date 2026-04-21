import CoreGraphics
import GuavaUIRuntime

/// Wires `node.overlayDraw` so that, while the controller's drag session is
/// active over this leaf, the leaf paints a 5-zone drop indicator on top of
/// its content. The closure runs every frame from `NodeRenderer`, so it
/// reads the live session state at draw time — no recompose required.
func installDropOverlay(node: Node, leafID: DockNodeID, controller: DockController) {
    node.overlayDraw = { [weak controller] list, origin in
        guard let controller else { return }
        let session = controller.dragSession
        guard session.isActive, let hit = session.dropHit, hit.leafID == leafID else { return }

        let appearance = node.compositionValue(of: DockStyleEnvironment.key)
            .resolve(DockStyleConfiguration(theme: node.theme))
        let accent = appearance.tabActiveAccentBar
        let fill = Color(r: accent.r, g: accent.g, b: accent.b, a: 0.25)
        let stroke = Color(r: accent.r, g: accent.g, b: accent.b, a: 0.85)

        let absX = Float(origin.x)
        let absY = Float(origin.y)
        let w = Float(node.frame.width)
        let h = Float(node.frame.height)

        let rect: UIRect
        switch hit.edge {
        case .left:
            rect = UIRect(x: absX, y: absY, width: w * 0.5, height: h)
        case .right:
            rect = UIRect(x: absX + w * 0.5, y: absY, width: w * 0.5, height: h)
        case .top:
            rect = UIRect(x: absX, y: absY, width: w, height: h * 0.5)
        case .bottom:
            rect = UIRect(x: absX, y: absY + h * 0.5, width: w, height: h * 0.5)
        case .center:
            rect = UIRect(x: absX, y: absY, width: w, height: h)
        }

        list.addRect(rect, color: fill)
        // Cheap 2-px stroke as four edge rects.
        let t: Float = 2
        list.addRect(UIRect(x: rect.x, y: rect.y, width: rect.width, height: t), color: stroke)
        list.addRect(UIRect(x: rect.x, y: rect.y + rect.height - t, width: rect.width, height: t), color: stroke)
        list.addRect(UIRect(x: rect.x, y: rect.y, width: t, height: rect.height), color: stroke)
        list.addRect(UIRect(x: rect.x + rect.width - t, y: rect.y, width: t, height: rect.height), color: stroke)
    }
}

/// Ghost preview rendered by the container root: a small label following the
/// cursor while a drag is active. Uses the root node's `overlayDraw` slot so
/// it paints above all leaf content.
func installDragGhostOverlay(node: Node, controller: DockController) {
    node.overlayDraw = { [weak controller] list, _ in
        guard let controller else { return }
        let session = controller.dragSession
        guard session.isActive, let ghost = session.ghost else { return }

        let appearance = node.compositionValue(of: DockStyleEnvironment.key)
            .resolve(DockStyleConfiguration(theme: node.theme))
        let accent = appearance.tabActiveAccentBar
        let bg = Color(r: 0, g: 0, b: 0, a: 0.55)

        // Coordinates from the session are window-absolute. The container
        // root paints in window-absolute coordinates as well (it's the
        // outermost node), so no translation is needed.
        let w: Float = 140
        let h: Float = 28
        let x = session.pointerX + 12
        let y = session.pointerY + 12

        list.addRect(UIRect(x: x, y: y, width: w, height: h), color: bg)
        // Accent bar at the bottom to suggest "this is a tab".
        list.addRect(UIRect(x: x, y: y + h - 2, width: w, height: 2), color: accent)
        _ = ghost  // Title rendering deferred — DrawList has no text helper at this layer.
    }
}
