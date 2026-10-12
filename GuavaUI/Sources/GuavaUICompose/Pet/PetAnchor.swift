//
//  PetAnchor.swift
//  GuavaUI · Software Pet
//
//  Layer 5 — the perch registration system.
//
//  Wrap any view with `.petAnchor("id")` to register it as a place the pet
//  can sit on or jump between. After every layout pass the anchor node reads
//  its own `absoluteFrame` (window space) and reports it to the world. When
//  the layout reflows, the next pass reports the new frame and the perched
//  pet follows — no manual coordinate bookkeeping.
//

import Foundation
import GuavaUICore
import GuavaUIScene
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Implicit channel for the active pet world. `PetScene` provides it; anchor
/// nodes consume it, so `.petAnchor(_:)` needs no explicit world reference.
public let PetWorldLocal = CompositionLocal<PetWorld?>(defaultValue: nil)

/// A primitive wrapper that reports its window-space frame after layout.
struct PetAnchorNode<Content: View>: _PrimitiveView {
    let id: String
    let content: Content

    func _makeNode() -> Node {
        let node = Node()
        // The wrapper itself doesn't capture pointer events; children do.
        node.isHitTestable = false
        hook(node)
        return node
    }

    func _updateNode(_ node: Node) {
        // Re-hook so the closure always captures the current id.
        hook(node)
    }

    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }

    var _children: [any View] { [content] }

    private func hook(_ node: Node) {
        node.layoutDidUpdate = { node in
            guard let world = node.compositionValue(of: PetWorldLocal) else { return }
            world.updateAnchor(id: id, frame: node.absoluteFrame)
        }
    }
}

public extension View {
    /// Mark this view as a pet perch with the given identifier.
    func petAnchor(_ id: String) -> some View {
        PetAnchorNode(id: id, content: self)
    }
}
