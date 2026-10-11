import Testing
import GuavaUIComposeCore

@Suite("Nonmodal focus accessories")
struct FocusAccessoryTests {
    @Test("A hovered portal remains in its owner's modal scope without stealing focus")
    func modalOwnership() {
        let chain = FocusChain(), window = Node(), modal = Node(), owner = Node(), previous = Node()
        let portal = Node(), action = Node(), backgroundOwner = Node(), backgroundPortal = Node(), forbidden = Node()
        window.addChild(modal); window.addChild(portal); window.addChild(backgroundOwner); window.addChild(backgroundPortal)
        modal.addChild(previous); modal.addChild(owner); portal.addChild(action); backgroundPortal.addChild(forbidden)
        previous.isFocusable = true; action.isFocusable = true; forbidden.isFocusable = true
        chain.beginModal(modal); chain.focus(previous, visible: false)
        chain.attachAccessory(portal, owner: owner)
        chain.attachAccessory(backgroundPortal, owner: backgroundOwner)
        #expect(chain.focused === previous && !chain.isFocusVisible)
        #expect(chain.permitsInput(action) && chain.permitsKeyboardInput(action))
        #expect(!chain.permitsInput(forbidden) && !chain.permitsKeyboardInput(forbidden))
        #expect(chain.accessoryRoots.count == 1 && chain.accessoryRoots.first === portal)
        chain.focus(action)
        chain.detachAccessory(portal)
        #expect(chain.focused === previous && !chain.isFocusVisible)
        #expect(!chain.permitsInput(action) && chain.accessoryRoots.isEmpty)
    }

    @Test("Logical ownership supports nested portals and rejects cycles and disabled owners")
    func nestingAndCycles() {
        let chain = FocusChain(), window = Node(), modal = Node(), owner = Node(), portal = Node(), nested = Node(), action = Node()
        window.addChild(modal); modal.addChild(owner); window.addChild(portal); window.addChild(nested); nested.addChild(action)
        chain.beginModal(modal)
        chain.attachAccessory(portal, owner: owner); chain.attachAccessory(nested, owner: portal)
        #expect(chain.permitsInput(action))
        owner.allowsHitTesting = false
        #expect(!chain.permitsInput(action) && chain.accessoryRoots.isEmpty)
        owner.allowsHitTesting = true
        chain.detachAccessory(portal)
        chain.attachAccessory(portal, owner: nested)
        #expect(!chain.permitsInput(action) && chain.accessoryRoots.isEmpty)
    }

    @Test("Leaf-first teardown restores previous focus while an unrelated new focus is preserved")
    func teardown() {
        let chain = FocusChain(), window = Node(), previous = Node(), other = Node(), portal = Node(), action = Node()
        window.addChild(previous); window.addChild(other); window.addChild(portal); portal.addChild(action)
        previous.isFocusable = true; other.isFocusable = true; action.isFocusable = true
        chain.focus(previous); chain.attachAccessory(portal, owner: previous); chain.focus(action)
        chain.clear() // Node teardown clears its focused leaf before the portal resource unmounts.
        chain.detachAccessory(portal)
        #expect(chain.focused === previous)
        chain.attachAccessory(portal, owner: previous); chain.focus(other)
        chain.detachAccessory(portal)
        #expect(chain.focused === other)
        chain.attachAccessory(portal, owner: previous); chain.focus(action)
        window.removeChild(other)
        chain.detachAccessory(portal)
        #expect(chain.focused == nil)
    }
}
