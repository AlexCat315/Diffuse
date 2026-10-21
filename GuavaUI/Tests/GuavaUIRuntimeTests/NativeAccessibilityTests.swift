#if os(macOS)
import AppKit
import Testing
@testable import GuavaUIRuntime

@Suite("Native accessibility", .serialized)
@MainActor
struct NativeAccessibilityTests {
    @Test("Stable native properties are reused while actions, focus and geometry stay live")
    func incrementalPresentation() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let button = Node(); button.frame = CGRect(x: 10, y: 10, width: 100, height: 30)
        button.isFocusable = true
        button.accessibility = AccessibilitySemantics(.button) { $0.label = "Run" }
        var first = 0, second = 0, deliveries = 0
        button.accessibilityActions.activate = { first += 1 }
        root.addChild(button)
        let bridge = MacAccessibilityBridge(view: window.contentView!)
        let focus = FocusChain()
        bridge.update(root: root, focus: focus, perform: { $0() })
        #expect(bridge.updatedElementCount == 1)
        let native = window.contentView!.accessibilityChildren()!.first as! NSAccessibilityElement
        bridge.update(root: root, focus: focus, perform: { deliveries += 1; $0() })
        #expect(bridge.updatedElementCount == 0)
        button.accessibilityActions.activate = { second += 1 }
        #expect(native.accessibilityPerformPress())
        #expect(first == 0 && second == 1 && deliveries == 1)
        let oldFrame = native.accessibilityFrame()
        button.frame.origin.x += 5
        bridge.update(root: root, focus: focus, perform: { $0() })
        #expect(bridge.updatedElementCount == 1)
        #expect(native.accessibilityFrame().minX == oldFrame.minX + 5)
        focus.focus(button, visible: true)
        bridge.update(root: root, focus: focus, perform: { $0() })
        #expect(native.isAccessibilityFocused())
        button.accessibility?.label = "Stop"
        button.accessibility?.state.isEnabled = false
        bridge.update(root: root, focus: focus, perform: { $0() })
        #expect(native.accessibilityLabel() == "Stop")
        #expect(!native.isAccessibilityEnabled() && !native.accessibilityPerformPress())
        root.removeChild(button)
        bridge.update(root: root, focus: focus, perform: { $0() })
        #expect(window.contentView!.accessibilityChildren()?.isEmpty == true)
        bridge.unmount(node: root)
    }

    @Test("Heading semantics preserve the complete title and use the platform heading role when available")
    func heading() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        let heading = Node(); heading.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        heading.accessibility = AccessibilitySemantics(.heading) { $0.label = "Full document title 👩🏽‍💻" }
        root.addChild(heading)
        let bridge = MacAccessibilityBridge(view: window.contentView!)
        bridge.update(root: root, focus: FocusChain(), perform: { $0() })
        let native = window.contentView!.accessibilityChildren()!.first as! NSAccessibilityElement
        #expect(native.accessibilityLabel() == "Full document title 👩🏽‍💻")
        if #available(macOS 26.0, *) { #expect(native.accessibilityRole() == .headingRole) }
        else { #expect(native.accessibilityRole() == .staticText) }
        bridge.unmount(node: root)
    }

    @Test("Pointer-transparent descriptions remain accessible while interactive actions stay blocked")
    func passiveDescriptions() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let overlay = Node(); overlay.frame = root.frame; overlay.allowsHitTesting = false
        root.addChild(overlay)
        let description = Node(); description.frame = CGRect(x: 10, y: 10, width: 200, height: 30)
        description.accessibility = AccessibilitySemantics(.staticText) { $0.label = "Symbol documentation" }
        overlay.addChild(description)
        let button = Node(); button.frame = CGRect(x: 10, y: 60, width: 100, height: 30)
        button.accessibility = AccessibilitySemantics(.button) { $0.label = "Inactive action" }
        var activations = 0; button.accessibilityActions.activate = { activations += 1 }
        overlay.addChild(button)
        let bridge = MacAccessibilityBridge(view: window.contentView!)
        bridge.update(root: root, focus: FocusChain(), perform: { $0() })
        let native = window.contentView!.accessibilityChildren() as! [NSAccessibilityElement]
        #expect(native.count == 2)
        #expect(native[0].isAccessibilityElement() && native[0].isAccessibilityEnabled())
        #expect(native[0].accessibilityRole() == .staticText)
        #expect(native[0].accessibilityValue() as? String == "Symbol documentation")
        #expect(native[0].accessibilityLabel() == nil)
        #expect(!native[1].isAccessibilityEnabled() && !native[1].accessibilityPerformPress())
        #expect(activations == 0)
        bridge.unmount(node: root)
    }

    @Test("Scene synchronization never materializes a lazy value; AppKit reads it on demand")
    func lazyValues() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let field = Node(); field.frame = CGRect(x: 10, y: 10, width: 200, height: 30)
        field.accessibility = AccessibilitySemantics(.textField)
        var reads = 0
        field.accessibilityValueProvider = AccessibilityValueProvider(revision: 1) { reads += 1; return "large text" }
        root.addChild(field)
        let bridge = MacAccessibilityBridge(view: window.contentView!)
        let focus = FocusChain()
        for _ in 0..<100 { bridge.update(root: root, focus: focus, perform: { $0() }) }
        #expect(reads == 0)
        let native = window.contentView!.accessibilityChildren()!.first as! NSAccessibilityElement
        #expect(native.accessibilityValue() as? String == "large text")
        #expect(reads == 1)
        field.accessibility!.state.isSecure = true
        field.accessibilityValueProvider = AccessibilityValueProvider(revision: 2) { reads += 1; return "secret" }
        bridge.update(root: root, focus: focus, perform: { $0() })
        #expect(reads == 1)
        #expect(native.accessibilityValue() as? String == "••••••")
        #expect(reads == 2)
        #expect(AccessibilityTree.snapshot(root: root).first?.semantics.value == "••••••")
        bridge.unmount(node: root)
    }

    @Test("AppKit controls expose real actions and values; removed elements cannot activate")
    func nativeLifecycle() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        let view = window.contentView!
        view.setAccessibilityElement(true)
        let original = NSAccessibilityElement(); original.setAccessibilityLabel("Original host element")
        view.setAccessibilityChildren([original])
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let button = Node(); button.frame = CGRect(x: 10, y: 10, width: 100, height: 30)
        button.isFocusable = true; button.accessibility = AccessibilitySemantics(.button) { $0.label = "Save" }
        var actions = 0
        button.accessibilityActions.activate = { actions += 1 }
        root.addChild(button)
        let field = Node(); field.frame = CGRect(x: 10, y: 60, width: 200, height: 30)
        field.accessibility = AccessibilitySemantics(.textField) { $0.label = "Password"; $0.value = "secret"; $0.state.isSecure = true }
        var text = "secret"
        field.accessibilityActions.setValue = { text = $0 }
        root.addChild(field)
        let bridge = MacAccessibilityBridge(view: view)
        root.addResource(bridge)
        let focus = FocusChain()
        bridge.update(root: root, focus: focus, perform: { $0() })
        let children = view.accessibilityChildren() as! [NSAccessibilityElement]
        #expect(children.count == 2 && children[0].accessibilityLabel() == "Save")
        #expect(children[0].accessibilityPerformPress() && actions == 1)
        #expect(children[1].accessibilitySubrole() == .secureTextField)
        #expect(children[1].accessibilityValue() as? String == "••••••")
        children[1].setAccessibilityValue("changed")
        #expect(text == "changed")
        root.removeChild(button)
        bridge.update(root: root, focus: focus, perform: { $0() })
        #expect(!children[0].accessibilityPerformPress() && actions == 1)
        bridge.unmount(node: root)
        #expect(view.isAccessibilityElement())
        #expect((view.accessibilityChildren()?.first as? NSAccessibilityElement) === original)
        #expect(!children[1].accessibilityPerformPress())
    }
}
#endif
