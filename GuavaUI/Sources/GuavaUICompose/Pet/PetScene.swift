//
//  PetScene.swift
//  GuavaUI · Software Pet
//
//  Layer 5 — the scene assembly.
//
//  Wrap your content in `PetScene(world:)`:
//  • normal content is laid out in-flow (mark perches with `.petAnchor(id)`);
//  • a single full-window overlay hosts the pet, so it is never clipped by a
//    parent's bounds and always renders above the UI;
//  • the world is provided through PetWorldLocal for anchor nodes.
//
//  ```swift
//  let world = PetWorld(spriteSheet: sheet, initialAnchorID: "a")
//  PetScene(world: world) {
//      Button("Home") { world.go(to: "a") }.petAnchor("a")
//      Button("Work") { world.go(to: "b") }.petAnchor("b")
//  }
//  ```
//

import Foundation
import GuavaUICore
import GuavaUIScene

public struct PetScene<Content: View>: View {
    let world: PetWorld
    let content: Content

    public init(world: PetWorld,
                @ViewBuilder content: () -> Content) {
        self.world = world
        self.content = content()
    }

    public var body: some View {
        Box {
            content
            PetOverlay(world: world)
        }
        .compositionLocal(PetWorldLocal, world)
    }
}
