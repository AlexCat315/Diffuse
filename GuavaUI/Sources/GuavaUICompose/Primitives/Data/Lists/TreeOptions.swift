import GuavaUIRuntime

/// Caller-owned selection and expansion, independent of transient pointer/drag state.
public struct TreeSelection<ID: Hashable> {
    public var primary: Binding<ID?> = .constant(nil)
    public var multiple: Binding<Set<ID>>?
    public var expanded: Binding<Set<ID>>?
    public var primaryKey: Binding<TreeNodeKey<ID>?> = .constant(nil)
    public var multipleKeys: Binding<Set<TreeNodeKey<ID>>>?
    public var expandedKeys: Binding<Set<TreeNodeKey<ID>>>?
    public init() {}
}

public struct TreeLayout: Equatable {
    public var rowHeight: Float = 30
    public var rowSpacing: Float = 0
    public var indentation: Float = 14
    public var disclosureWidth: Float = 18
    public var showsIndentGuides = true
    public var trailingSlotWidth: Float = 64
    public init() {}
    mutating func validate() {
        rowHeight = max(1, rowHeight)
        rowSpacing = max(0, rowSpacing)
        indentation = max(0, indentation)
        disclosureWidth = max(0, disclosureWidth)
        trailingSlotWidth = max(0, trailingSlotWidth)
    }
}

public struct TreeSlots<Element> {
    public var disclosure: ((Bool) -> AnyView)?
    public var trailing: ((Element, Bool, Bool, Bool, Bool, Int) -> AnyView)?
    public init() {}
}

public struct TreeSearch<Element> {
    public var query = ""
    public var text: ((Element) -> String)?
    public var policy: TreeSearchFilterPolicy = .filterAndAutoExpand
    public init() {}
}

public struct TreeEvents<Element, ID: Hashable> {
    public var onKeyCommand: ((KeyEvent, Set<ID>) -> Bool)?
    public var onSelect: ((Element) -> Void)?
    public init() {}
}

public struct TreeDragOperations<Element> {
    public var canDrop: ((Element, Element, TreeDropPosition) -> Bool)?
    public var onDrop: ((Element, Element, TreeDropPosition) -> Void)?
    public init() {}
}

/// Configuration consists of independently reusable groups. The row renderer's generic
/// type is deliberately absent, so Swift can infer trailing row-content closures.
public struct TreeOptions<Element, ID: Hashable> {
    public var selection = TreeSelection<ID>()
    public var layout = TreeLayout()
    public var slots = TreeSlots<Element>()
    public var search = TreeSearch<Element>()
    public var events = TreeEvents<Element, ID>()
    public var drag = TreeDragOperations<Element>()
    public init() {}
}
