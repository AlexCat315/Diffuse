import GuavaUIRuntime

/// Marker for views that don't materialise into a node themselves but expand
/// into a sequence of child views (`TupleView`, `_ConditionalContent`,
/// `Optional`, `Array<View>`).
///
/// Internal — user views never conform to this directly.
public protocol _StructuralView: View where Body == Never {
    var _expanded: [any View] { get }
}

extension TupleView: _StructuralView {
    public var _expanded: [any View] {
        var out: [any View] = []
        let mirror = Mirror(reflecting: value)
        // Tuples reflect their elements as anonymous children; non-tuples reflect
        // a single value with no children — fall back to the value itself.
        if mirror.children.isEmpty {
            if let v = value as? any View { out.append(v) }
        } else {
            for child in mirror.children {
                if let v = child.value as? any View { out.append(v) }
            }
        }
        return out
    }
}

extension _ConditionalContent: _StructuralView {
    public var _expanded: [any View] {
        switch self {
        case .first(let v):  return [v]
        case .second(let v): return [v]
        }
    }
}

extension Optional: _StructuralView where Wrapped: View {
    public var _expanded: [any View] {
        if let v = self { return [v] } else { return [] }
    }
}

extension Array: _StructuralView where Element: View {
    public var _expanded: [any View] { map { $0 as any View } }
}
