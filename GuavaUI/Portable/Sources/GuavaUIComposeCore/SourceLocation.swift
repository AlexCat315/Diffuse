import GuavaUIScene

public protocol _AnySourceLocatedView {
    var _sourceContent: any View { get }
    var _sourceLocation: ComponentSourceLocation { get }
}

/// Transparent to node identity, keyed reconciliation and state reflection.
public struct _SourceLocatedView<Content: View>: View, _AnySourceLocatedView {
    public let content: Content
    public let location: ComponentSourceLocation
    public var _sourceContent: any View { content }
    public var _sourceLocation: ComponentSourceLocation { location }
    public var body: Never { fatalError("Source metadata is unwrapped by ViewGraph") }
}

struct ErasedSourceLocatedView: View, _AnySourceLocatedView {
    let _sourceContent: any View
    let _sourceLocation: ComponentSourceLocation
    var body: Never { fatalError("Source metadata is unwrapped by ViewGraph") }
}

public extension View {
    /// Mark explicit-return bodies, erased/manual child lists or generated views.
    /// Default compiler arguments capture this call, not this helper's file.
    func sourceLocation(fileID: StaticString = #fileID, filePath: StaticString = #filePath,
                        line: UInt = #line, column: UInt = #column) -> _SourceLocatedView<Self> {
        _SourceLocatedView(content: self, location: ComponentSourceLocation(fileID: String(describing: fileID),
            filePath: String(describing: filePath), line: line, column: column, explicit: true))
    }
}
