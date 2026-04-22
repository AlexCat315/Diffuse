import CoreGraphics
import GuavaUIRuntime

struct DockDropGuideTile {
    let edge: DockEdge
    let buttonRect: UIRect
    let miniatureRect: UIRect
    let highlightRect: UIRect
}

func makeDockDropGuideTiles(in leafRect: UIRect) -> [DockDropGuideTile] {
    let minDimension = min(leafRect.width, leafRect.height)
    guard minDimension >= 72 else { return [] }

    let buttonSize = max(18, min(28, (minDimension - 24) / 3))
    let gap = max(6, min(10, buttonSize * 0.3))
    let centerX = leafRect.x + leafRect.width * 0.5
    let centerY = leafRect.y + leafRect.height * 0.5
    let buttonHalf = buttonSize * 0.5
    let iconInset = max(4, buttonSize * 0.22)

    func tile(edge: DockEdge, x: Float, y: Float) -> DockDropGuideTile {
        let buttonRect = UIRect(x: x, y: y, width: buttonSize, height: buttonSize)
        let miniatureRect = UIRect(x: x + iconInset,
                                   y: y + iconInset,
                                   width: buttonSize - iconInset * 2,
                                   height: buttonSize - iconInset * 2)
        let highlightRect: UIRect
        switch edge {
        case .left:
            let width = miniatureRect.width * 0.36
            highlightRect = UIRect(x: miniatureRect.x,
                                   y: miniatureRect.y,
                                   width: width,
                                   height: miniatureRect.height)
        case .right:
            let width = miniatureRect.width * 0.36
            highlightRect = UIRect(x: miniatureRect.x + miniatureRect.width - width,
                                   y: miniatureRect.y,
                                   width: width,
                                   height: miniatureRect.height)
        case .top:
            let height = miniatureRect.height * 0.36
            highlightRect = UIRect(x: miniatureRect.x,
                                   y: miniatureRect.y,
                                   width: miniatureRect.width,
                                   height: height)
        case .bottom:
            let height = miniatureRect.height * 0.36
            highlightRect = UIRect(x: miniatureRect.x,
                                   y: miniatureRect.y + miniatureRect.height - height,
                                   width: miniatureRect.width,
                                   height: height)
        case .center:
            highlightRect = miniatureRect
        }
        return DockDropGuideTile(edge: edge,
                                 buttonRect: buttonRect,
                                 miniatureRect: miniatureRect,
                                 highlightRect: highlightRect)
    }

    return [
        tile(edge: .top,
             x: centerX - buttonHalf,
             y: centerY - buttonSize - gap),
        tile(edge: .left,
             x: centerX - buttonSize - gap,
             y: centerY - buttonHalf),
        tile(edge: .center,
             x: centerX - buttonHalf,
             y: centerY - buttonHalf),
        tile(edge: .right,
             x: centerX + gap,
             y: centerY - buttonHalf),
        tile(edge: .bottom,
             x: centerX - buttonHalf,
             y: centerY + gap)
    ]
}

private func drawDropGuide(list: DrawList,
                           leafRect: UIRect,
                           activeEdge: DockEdge,
                           appearance: DockAppearance,
                           theme: Theme) {
    let tiles = makeDockDropGuideTiles(in: leafRect)
    guard !tiles.isEmpty else { return }

    let buttonSpan = tiles.map(\ .buttonRect)
    guard let minX = buttonSpan.map(\ .x).min(),
          let minY = buttonSpan.map(\ .y).min(),
          let maxX = buttonSpan.map({ $0.x + $0.width }).max(),
          let maxY = buttonSpan.map({ $0.y + $0.height }).max() else {
        return
    }

    let backdrop = UIRect(x: minX - 8,
                          y: minY - 8,
                          width: (maxX - minX) + 16,
                          height: (maxY - minY) + 16)
    let backdropColor = theme.colors.surfaceFloating
        .composited(over: Color.black.multipliedAlpha(0.18))
        .multipliedAlpha(0.94)
    list.addRoundedRect(backdrop, radius: 14, color: backdropColor)

    let inactiveFill = appearance.tabBarBackground
        .composited(over: Color.black.multipliedAlpha(0.08))
        .multipliedAlpha(0.98)
    let inactiveMiniature = appearance.tabInactiveForeground.multipliedAlpha(0.16)
    let activeFillOverlay = appearance.tabActiveAccentBar.multipliedAlpha(0.2)
    let activeMiniature = appearance.tabActiveAccentBar.multipliedAlpha(0.92)
    let activeStroke = appearance.tabActiveAccentBar.multipliedAlpha(0.85)
    let inactiveStroke = appearance.tabInactiveForeground.multipliedAlpha(0.22)

    for tile in tiles {
        let isActive = tile.edge == activeEdge
        let buttonColor = isActive
            ? inactiveFill.composited(over: activeFillOverlay)
            : inactiveFill
        let strokeColor = isActive ? activeStroke : inactiveStroke
        list.addRoundedRect(tile.buttonRect, radius: 8, color: buttonColor)
        let topStroke = UIRect(x: tile.buttonRect.x,
                               y: tile.buttonRect.y,
                               width: tile.buttonRect.width,
                               height: 1.5)
        let bottomStroke = UIRect(x: tile.buttonRect.x,
                                  y: tile.buttonRect.y + tile.buttonRect.height - 1.5,
                                  width: tile.buttonRect.width,
                                  height: 1.5)
        let leftStroke = UIRect(x: tile.buttonRect.x,
                                y: tile.buttonRect.y,
                                width: 1.5,
                                height: tile.buttonRect.height)
        let rightStroke = UIRect(x: tile.buttonRect.x + tile.buttonRect.width - 1.5,
                                 y: tile.buttonRect.y,
                                 width: 1.5,
                                 height: tile.buttonRect.height)
        list.addRect(topStroke, color: strokeColor)
        list.addRect(bottomStroke, color: strokeColor)
        list.addRect(leftStroke, color: strokeColor)
        list.addRect(rightStroke, color: strokeColor)
        list.addRoundedRect(tile.miniatureRect, radius: 3, color: inactiveMiniature)
        list.addRoundedRect(tile.highlightRect,
                            radius: 2,
                            color: isActive ? activeMiniature : activeMiniature.multipliedAlpha(0.45))
    }
}

/// Wires `node.overlayDraw` so that, while the controller's drag session is
/// active over this leaf, the leaf paints a 5-zone drop indicator on top of
/// its content. The closure runs every frame from `NodeRenderer`, so it
/// reads the live session state at draw time — no recompose required.
func installDropOverlay(node: Node, leafID: DockNodeID, controller: DockController) {
    node.overlayDraw = { [weak controller] list, origin in
        guard let controller else { return }
        let session = controller.dragSession
        guard session.isActive, let hit = session.dropHit, hit.leafID == leafID else { return }
        // Phase G — only the lift-tier intent draws the 5-direction edge
        // indicator. Reorder-tier drags are visualised by the ghost only.
        guard session.intent == .detachOrSplit else { return }

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

        drawDropGuide(list: list,
                      leafRect: UIRect(x: absX, y: absY, width: w, height: h),
                      activeEdge: hit.edge,
                      appearance: appearance,
                      theme: node.theme)
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
        let bg = Color(r: 0, g: 0, b: 0, a: 0.72)
        let textColor = appearance.tabActiveForeground

        // Coordinates from the session are window-absolute. The container
        // root paints in window-absolute coordinates as well (it's the
        // outermost node), so no translation is needed.
        let env = TextEnvironmentHolder.current
        let font = env?.defaultFont ?? Font(size: 13, weight: .regular)
        let lineHeight = env?.defaultLineHeight ?? 18
        let padX: Float = 10
        let padY: Float = 4

        // Measure the title; fall back to a fixed width if no text env.
        var textWidth: Float = 100
        var layout: TextLayoutResult?
        if let env {
            let glyphs = env.shape(text: ghost.title, font: font)
            let result = TextLayout.layout(shapedGlyphs: glyphs,
                                           text: ghost.title,
                                           atlas: env.atlas,
                                           maxWidth: .infinity,
                                           lineHeight: lineHeight,
                                           alignment: .leading)
            textWidth = result.totalWidth
            layout = result
        }

        let w = max(80, min(220, textWidth + padX * 2))
        let h: Float = lineHeight + padY * 2
        // Anchor under the cursor, slightly offset so the cursor stays
        // visible at the top-left corner of the ghost.
        let x = session.pointerX + 12
        let y = session.pointerY + 12

        list.addRect(UIRect(x: x, y: y, width: w, height: h), color: bg)
        // Accent bar at the bottom acts as the "this is a tab" affordance.
        list.addRect(UIRect(x: x, y: y + h - 2, width: w, height: 2), color: accent)

        if let env, let layout {
            list.addText(layout,
                         origin: (x: x + padX, y: y + padY),
                         color: textColor,
                         textureID: env.atlasTextureID)
        }
    }
}
