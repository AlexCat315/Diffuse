import GuavaUIRuntime

public struct BoundedScrollView: View {
    public let axes: ScrollView<AnyView>.Axis
    public let contentHeight: Float
    public let minHeight: Float
    public let maxHeight: Float
    public let consumePolicy: ScrollConsumePolicy
    public let scrollbarGutter: ScrollView<AnyView>.ScrollbarGutter
    public let content: AnyView

    public init<Content: View>(_ axes: ScrollView<AnyView>.Axis = .vertical,
                               contentHeight: Float,
                               minHeight: Float,
                               maxHeight: Float,
                               consumePolicy: ScrollConsumePolicy = .whenOffsetChanged,
                               scrollbarGutter: ScrollView<AnyView>.ScrollbarGutter = .stable,
                               @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.contentHeight = contentHeight
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.consumePolicy = consumePolicy
        self.scrollbarGutter = scrollbarGutter
        self.content = AnyView(content())
    }

    public var viewportHeight: Float {
        Self.viewportHeight(contentHeight: contentHeight,
                            minHeight: minHeight,
                            maxHeight: maxHeight)
    }

    public var body: some View {
        ScrollView(axes,
                   consumePolicy: consumePolicy,
                   scrollbarGutter: scrollbarGutter) {
            AnyView(content.frame(height: contentHeight))
        }
        .frame(height: viewportHeight)
    }

    public static func viewportHeight(contentHeight: Float,
                                      minHeight: Float,
                                      maxHeight: Float) -> Float {
        min(max(contentHeight, minHeight), maxHeight)
    }
}
