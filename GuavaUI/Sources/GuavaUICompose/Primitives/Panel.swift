import GuavaUIRuntime

public struct Panel<Accessory: View, Content: View>: View {
    public let title: String
    public let headerHeight: Float
    public let cornerRadius: Float
    public let chromeColor: Color
    public let headerColor: Color
    public let borderColor: Color
    public let titleColor: Color
    public let contentPadding: EdgeInsets
    public let accessory: Accessory
    public let content: Content

    public init(_ title: String,
                headerHeight: Float = 36,
                cornerRadius: Float = 10,
                chromeColor: Color = Color(r: 0.14, g: 0.17, b: 0.22),
                headerColor: Color = Color(r: 0.18, g: 0.21, b: 0.26),
                borderColor: Color = Color(r: 0.23, g: 0.26, b: 0.31),
                titleColor: Color = Color.white,
                contentPadding: EdgeInsets = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12),
                @ViewBuilder accessory: () -> Accessory,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.headerHeight = headerHeight
        self.cornerRadius = cornerRadius
        self.chromeColor = chromeColor
        self.headerColor = headerColor
        self.borderColor = borderColor
        self.titleColor = titleColor
        self.contentPadding = contentPadding
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        Column(alignment: .leading, spacing: 0) {
            Row(alignment: .center, spacing: 8) {
                Text(title, color: titleColor)
                    .font(.system(size: 14, weight: .bold))
                Spacer(minLength: 0)
                accessory
            }
            .padding(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .frame(height: headerHeight)
            .background(headerColor)

            Divider(color: borderColor)

            Box(direction: .column, alignItems: .stretch) {
                content
            }
            .flex()
            .padding(contentPadding)
        }
        .background(chromeColor)
        .cornerRadius(cornerRadius)
        .clipped()
    }
}

public extension Panel where Accessory == EmptyView {
    init(_ title: String,
         headerHeight: Float = 36,
         cornerRadius: Float = 10,
         chromeColor: Color = Color(r: 0.14, g: 0.17, b: 0.22),
         headerColor: Color = Color(r: 0.18, g: 0.21, b: 0.26),
         borderColor: Color = Color(r: 0.23, g: 0.26, b: 0.31),
         titleColor: Color = Color.white,
         contentPadding: EdgeInsets = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12),
         @ViewBuilder content: () -> Content) {
        self.init(title,
                  headerHeight: headerHeight,
                  cornerRadius: cornerRadius,
                  chromeColor: chromeColor,
                  headerColor: headerColor,
                  borderColor: borderColor,
                  titleColor: titleColor,
                  contentPadding: contentPadding,
                  accessory: { EmptyView() },
                  content: content)
    }
}