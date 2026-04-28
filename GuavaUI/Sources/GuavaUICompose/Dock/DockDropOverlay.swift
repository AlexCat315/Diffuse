import CoreGraphics
import GuavaUIRuntime

struct DockDropGuideTile {
    let edge: DockEdge
    let buttonRect: UIRect
    let miniatureRect: UIRect
    let highlightRect: UIRect
}

private func makeDropGuideTile(edge: DockEdge,
                               x: Float,
                               y: Float,
                               buttonSize: Float,
                               iconInset: Float) -> DockDropGuideTile {
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

func makeDockDropGuideTiles(in leafRect: UIRect) -> [DockDropGuideTile] {
    let minDimension = min(leafRect.width, leafRect.height)
    guard minDimension >= 72 else { return [] }

    let buttonSize = max(18, min(28, (minDimension - 24) / 3))
    let gap = max(6, min(10, buttonSize * 0.3))
    let centerX = leafRect.x + leafRect.width * 0.5
    let centerY = leafRect.y + leafRect.height * 0.5
    let buttonHalf = buttonSize * 0.5
    let iconInset = max(4, buttonSize * 0.22)

    return [
        makeDropGuideTile(edge: .top,
                          x: centerX - buttonHalf,
                          y: centerY - buttonSize - gap,
                          buttonSize: buttonSize,
                          iconInset: iconInset),
        makeDropGuideTile(edge: .left,
                          x: centerX - buttonSize - gap,
                          y: centerY - buttonHalf,
                          buttonSize: buttonSize,
                          iconInset: iconInset),
        makeDropGuideTile(edge: .center,
                          x: centerX - buttonHalf,
                          y: centerY - buttonHalf,
                          buttonSize: buttonSize,
                          iconInset: iconInset),
        makeDropGuideTile(edge: .right,
                          x: centerX + gap,
                          y: centerY - buttonHalf,
                          buttonSize: buttonSize,
                          iconInset: iconInset),
        makeDropGuideTile(edge: .bottom,
                          x: centerX - buttonHalf,
                          y: centerY + gap,
                          buttonSize: buttonSize,
                          iconInset: iconInset)
    ]
}

func makeWorkspaceDropGuideTiles(in workspaceRect: UIRect) -> [DockDropGuideTile] {
    let minDimension = min(workspaceRect.width, workspaceRect.height)
    guard minDimension >= 120 else { return [] }

    let buttonSize = max(24, min(40, (minDimension - 48) / 4))
    let gap = max(12, min(20, buttonSize * 0.45))
    let centerX = workspaceRect.x + workspaceRect.width * 0.5
    let centerY = workspaceRect.y + workspaceRect.height * 0.5
    let buttonHalf = buttonSize * 0.5
    let iconInset = max(5, buttonSize * 0.2)

    return [
        makeDropGuideTile(edge: .top,
                          x: centerX - buttonHalf,
                          y: centerY - buttonSize - gap,
                          buttonSize: buttonSize,
                          iconInset: iconInset),
        makeDropGuideTile(edge: .left,
                          x: centerX - buttonSize - gap,
                          y: centerY - buttonHalf,
                          buttonSize: buttonSize,
                          iconInset: iconInset),
        makeDropGuideTile(edge: .right,
                          x: centerX + gap,
                          y: centerY - buttonHalf,
                          buttonSize: buttonSize,
                          iconInset: iconInset),
        makeDropGuideTile(edge: .bottom,
                          x: centerX - buttonHalf,
                          y: centerY + gap,
                          buttonSize: buttonSize,
                          iconInset: iconInset)
    ]
}

private func drawGuideTiles(list: DrawList,
                            tiles: [DockDropGuideTile],
                            activeEdge: DockEdge?,
                            appearance: DockAppearance,
                            theme: Theme) {
    guard !tiles.isEmpty else { return }

    let buttonSpan = tiles.map(\.buttonRect)
    guard let minX = buttonSpan.map(\.x).min(),
          let minY = buttonSpan.map(\.y).min(),
          let maxX = buttonSpan.map({ $0.x + $0.width }).max(),
          let maxY = buttonSpan.map({ $0.y + $0.height }).max() else {
        return
    }

    let backdrop = UIRect(x: minX - 8,
                          y: minY - 8,
                          width: (maxX - minX) + 16,
                          height: (maxY - minY) + 16)
    let backdropColor = theme.colors.surfaceFloating
        .composited(over: Color.black.multipliedAlpha(0.12))
        .multipliedAlpha(0.88)
    list.addRoundedRect(backdrop, radius: 10, color: backdropColor)

    let inactiveFill = appearance.tabBarBackground
        .composited(over: Color.black.multipliedAlpha(0.05))
        .multipliedAlpha(0.96)
    let inactiveMiniature = appearance.tabInactiveForeground.multipliedAlpha(0.13)
    let activeFillOverlay = appearance.tabActiveAccentBar.multipliedAlpha(0.18)
    let activeMiniature = appearance.tabActiveAccentBar.multipliedAlpha(0.88)
    let activeStroke = appearance.tabActiveAccentBar.multipliedAlpha(0.78)
    let inactiveStroke = appearance.tabInactiveForeground.multipliedAlpha(0.18)

    for tile in tiles {
        let isActive = tile.edge == activeEdge
        let buttonColor = isActive
            ? inactiveFill.composited(over: activeFillOverlay)
            : inactiveFill
        let strokeColor = isActive ? activeStroke : inactiveStroke
        list.addRoundedRect(tile.buttonRect, radius: 7, color: buttonColor)
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

private func drawDropGuide(list: DrawList,
                           leafRect: UIRect,
                           activeEdge: DockEdge?,
                           appearance: DockAppearance,
                           theme: Theme) {
    drawGuideTiles(list: list,
                   tiles: makeDockDropGuideTiles(in: leafRect),
                   activeEdge: activeEdge,
                   appearance: appearance,
                   theme: theme)
}

private func drawWorkspaceDropGuide(list: DrawList,
                                    workspaceRect: UIRect,
                                    activeEdge: DockEdge?,
                                    appearance: DockAppearance,
                                    theme: Theme) {
    drawGuideTiles(list: list,
                   tiles: makeWorkspaceDropGuideTiles(in: workspaceRect),
                   activeEdge: activeEdge,
                   appearance: appearance,
                   theme: theme)
}

private func previewRect(for edge: DockEdge, in frame: UIRect) -> UIRect {
    switch edge {
    case .left:
        return UIRect(x: frame.x, y: frame.y, width: frame.width * 0.5, height: frame.height)
    case .right:
        return UIRect(x: frame.x + frame.width * 0.5, y: frame.y, width: frame.width * 0.5, height: frame.height)
    case .top:
        return UIRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height * 0.5)
    case .bottom:
        return UIRect(x: frame.x, y: frame.y + frame.height * 0.5, width: frame.width, height: frame.height * 0.5)
    case .center:
        return UIRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}

private func drawDropPreview(list: DrawList,
                             rect: UIRect,
                             fill: Color,
                             stroke: Color) {
    let inset: Float = 2
    let rect = UIRect(x: rect.x + inset,
                      y: rect.y + inset,
                      width: max(0, rect.width - inset * 2),
                      height: max(0, rect.height - inset * 2))
    list.addRoundedRect(rect, radius: 8, color: fill)
    let t: Float = 2
    list.addRect(UIRect(x: rect.x, y: rect.y, width: rect.width, height: t), color: stroke)
    list.addRect(UIRect(x: rect.x, y: rect.y + rect.height - t, width: rect.width, height: t), color: stroke)
    list.addRect(UIRect(x: rect.x, y: rect.y, width: t, height: rect.height), color: stroke)
    list.addRect(UIRect(x: rect.x + rect.width - t, y: rect.y, width: t, height: rect.height), color: stroke)
}

/// Wires `node.overlayDraw` so that, while the controller's drag session is
/// active over this leaf, the leaf paints a 5-zone drop indicator on top of
/// its content. The closure runs every frame from `NodeRenderer`, so it
/// reads the live session state at draw time — no recompose required.
func installDropOverlay(node: Node, leafID: DockNodeID, controller: DockController) {
    node.overlayDraw = { [weak controller] list, origin in
        guard let controller else { return }
        let session = controller.dragSession
        guard session.isActive, session.hoverLeafID == leafID else { return }
        // Phase G — only the lift-tier intent draws the 5-direction edge
        // indicator. Reorder-tier drags are visualised by the ghost only.
        guard session.intent == .detachOrSplit else { return }
        // Note: when the source leaf IS the target leaf, we still draw the
        // guide tiles so the user can see edge drop targets even though
        // the centre drop is a no-op. The active-edge highlight will only
        // light up for genuine cross-leaf hits via the dropHit check below.
        if let hit = session.dropHit, hit.scope == .workspace {
            return
        }

        let appearance = node.compositionValue(of: DockStyleEnvironment.key)
            .resolve(DockStyleConfiguration(theme: node.theme))
        let accent = appearance.tabActiveAccentBar
        let fill = Color(r: accent.r, g: accent.g, b: accent.b, a: 0.25)
        let stroke = Color(r: accent.r, g: accent.g, b: accent.b, a: 0.85)

        let absX = Float(origin.x)
        let absY = Float(origin.y)
        let w = Float(node.frame.width)
        let h = Float(node.frame.height)
        let frame = UIRect(x: absX, y: absY, width: w, height: h)

        if let hit = session.dropHit, hit.scope == .leaf, hit.leafID == leafID {
            drawDropPreview(list: list,
                            rect: previewRect(for: hit.edge, in: frame),
                            fill: fill,
                            stroke: stroke)
        }

        drawDropGuide(list: list,
                      leafRect: frame,
                      activeEdge: session.dropHit?.scope == .leaf && session.dropHit?.leafID == leafID ? session.dropHit?.edge : nil,
                      appearance: appearance,
                      theme: node.theme)
    }
}

/// Ghost preview rendered by the container root: a small label following the
/// cursor while a drag is active. Uses the root node's `overlayDraw` slot so
/// it paints above all leaf content.
func installDragGhostOverlay(node: Node,
                             controller: DockController,
                             rootNodeID: DockNodeID) {
    node.overlayDraw = { [weak controller] list, origin in
        guard let controller else { return }
        let session = controller.dragSession
        let appearance = node.compositionValue(of: DockStyleEnvironment.key)
            .resolve(DockStyleConfiguration(theme: node.theme))
        let accent = appearance.tabActiveAccentBar
        let rootRect = UIRect(x: Float(origin.x),
                              y: Float(origin.y),
                              width: Float(node.frame.width),
                              height: Float(node.frame.height))
        let showWorkspaceGuide = session.isActive
            && session.intent == .detachOrSplit
            && (session.dropHit?.scope == .workspace
                || (session.hoverLeafID == nil && session.dropHit == nil))
        if showWorkspaceGuide {
            drawWorkspaceDropGuide(list: list,
                                   workspaceRect: rootRect,
                                   activeEdge: session.dropHit?.scope == .workspace ? session.dropHit?.edge : nil,
                                   appearance: appearance,
                                   theme: node.theme)
        }
        if session.isActive,
           session.intent == .detachOrSplit,
           let hit = session.dropHit,
           hit.scope == .workspace {
            let fill = Color(r: accent.r, g: accent.g, b: accent.b, a: 0.18)
            let stroke = Color(r: accent.r, g: accent.g, b: accent.b, a: 0.78)
            drawDropPreview(list: list,
                            rect: previewRect(for: hit.edge, in: rootRect),
                            fill: fill,
                            stroke: stroke)
        }

        guard session.isActive, let ghost = session.ghost else { return }

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
                         textureID: env.atlasTextureID,
                         atlas: env.atlas)
        }
    }
}
