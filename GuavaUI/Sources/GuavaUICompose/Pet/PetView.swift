//
//  PetView.swift
//  GuavaUI · Software Pet
//
//  Layer 4 — the renderer.
//
//  The view is a pure function of `world.render`:
//  • PetSpriteView (a user scope) observes the world and embeds...
//  • PetSpriteCanvas (a primitive), whose draw hook emits a single quad.
//
//  The quad applies the composed transform every frame:
//  world (translation · facing) × local (squash/stretch) · presence alpha.
//  Sprites are drawn foot-anchored: the quad's bottom-centre sits exactly on
//  `render.position`, so squash/stretch pivots around the feet.
//

import Foundation
import GuavaUICore
import GuavaUIScene
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - User scope (observes the world)

struct PetSpriteView: View {
    // Observe the world's render state: changes invalidate this scope and
    // refresh the canvas below.
    private var _render: Observed<PetWorld, PetRenderState>
    private let world: PetWorld

    init(world: PetWorld) {
        self.world = world
        _render = Observed(\.render, on: world)
    }

    var body: some View {
        PetSpriteCanvas(world: world)
    }
}

// MARK: - Primitive canvas

struct PetSpriteCanvas: _PrimitiveView {
    let world: PetWorld

    func _makeNode() -> Node {
        let node = Node()
        // The canvas itself is non-interactive; anchors/buttons handle input.
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        let r = world.render
        let sheet = world.spriteSheet
        // Identity = the render state: the hook is refreshed (and the node
        // marked dirty) only when the pet actually changes.
        node.updateDraw(identity: r) { list, _ in
            PetSpriteCanvas.paint(list: list, render: r, sheet: sheet)
        }
    }

    // The canvas takes no layout space; it draws directly in window space.
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = 0
        layout.height = 0
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.width = 0
        layout.height = 0
    }

    // MARK: Painting

    static func paint(list: DrawList, render r: PetRenderState, sheet: PetSpriteSheet) {
        guard r.presence > 0.01,
              let path = sheet.resolvedPath(for: r.pose) else { return }

        // Resolve via the shared asset cache (no re-decode across frames).
        let source = Image.resolve(path: path,
                                   width: sheet.displaySize,
                                   height: sheet.displaySize)
        source.retain(in: list)

        // Local squash/stretch dimensions.
        let w = CGFloat(sheet.displaySize) * CGFloat(r.scaleX)
        let h = CGFloat(sheet.displaySize) * CGFloat(r.scaleY)

        // Foot-anchored placement: bottom-centre on render.position.
        let left = r.position.x - w / 2
        let top  = r.position.y - h
        let rect = UIRect(x: Float(left), y: Float(top),
                          width: Float(w), height: Float(h))

        // Facing flips the horizontal UVs (no mirror asset needed).
        let flip = r.facing < 0
        let uvMin = (x: Float(flip ? 1 : 0), y: Float(0))
        let uvMax = (x: Float(flip ? 0 : 1), y: Float(1))

        let tint = Color(r: 1, g: 1, b: 1, a: r.presence)
        list.addImageQuad(rect: rect, textureID: source.textureID,
                          tint: tint, uvMin: uvMin, uvMax: uvMax)
    }
}

// MARK: - Full-window overlay

/// The non-interactive layer that hosts the pet above all content.
struct PetOverlay: View {
    let world: PetWorld

    var body: some View {
        PetSpriteView(world: world)
            // Fill the whole parent (window) so the canvas can draw anywhere
            // in window coordinates. The layer captures no pointer events.
            .absolutePosition(left: 0, top: 0, right: 0, bottom: 0)
    }
}
