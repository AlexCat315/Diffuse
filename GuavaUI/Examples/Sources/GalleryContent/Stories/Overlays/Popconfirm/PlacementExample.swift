import GuavaUI

struct PopoverPlacementExample: View {
  let options: GalleryOptions
  let onAction: (String) -> Void
  @State private var selected = 1
  private static let variants: [(String, PopoverPlacement)] = [
    ("TL", .topLeading), ("Top", .top), ("TR", .topTrailing),
    ("LT", .leadingTop), ("Left", .leading), ("LB", .leadingBottom),
    ("RT", .trailingTop), ("Right", .trailing), ("RB", .trailingBottom),
    ("BL", .bottomLeading), ("Bottom", .bottom), ("BR", .bottomTrailing)
  ]
  var body: some View {
    ThemeReader { theme in
      Box(direction: .row, justifyContent: .center) {
        Box(direction: .column, alignItems: .stretch, spacing: 10) {
          Text("Placement playground").font(.bodyStrong)
          Text("Named sides stay on that side. The card and pointer are shared with Popover.")
            .font(.caption).foregroundColor(.onSurfaceMuted)
          TextScalerReader { scaler in
          ContainerSizeReader { size in
            if size.width >= 340 {
              Box(direction: .column, alignItems: .stretch, spacing: 8) {
                Box(direction: .row, justifyContent: .center, spacing: 8) {
                  preview(0); preview(1); preview(2)
                }
                sidePair(3, 6)
                Box(direction: .row, alignItems: .center, justifyContent: .spaceBetween, spacing: 8) {
                  preview(4)
                  Text("Anchor").font(.caption).foregroundColor(.onSurfaceMuted)
                  preview(7)
                }
                sidePair(5, 8)
                Box(direction: .row, justifyContent: .center, spacing: 8) {
                  preview(9); preview(10); preview(11)
                }
              }
            } else {
              Box(direction: .column, alignItems: .stretch, spacing: 12) {
                Select(selection: $selected,
                       options: Self.variants.enumerated().map { SelectOption(value: $0.offset, label: $0.element.0) },
                       isEnabled: options.isEnabled)
                compactPreview(width: Float(size.width), triggerWidth: min(Float(size.width), max(80, scaler.scale(70))))
              }
            }
          }.frame(height: max(240, scaler.scale(32) * 5 + 32)).debugName("popover-placement-preview")
          }
        }.padding(14).background(.surface).cornerRadius(theme.radius.md).border(.border, width: 1)
          .frame(width: .percent(100), maxWidth: 400)
      }
    }
  }
  private func sidePair(_ left: Int, _ right: Int) -> some View {
    Box(direction: .row, justifyContent: .spaceBetween, spacing: 8) { preview(left); preview(right) }
  }
  private func preview(_ index: Int) -> some View {
    let item = Self.variants[index]
    return Popconfirm(item.0, title: "\(item.0) placement",
                      message: "The bubble stays on the requested side of its trigger.",
                      confirmTitle: "OK", placement: item.1, isEnabled: options.isEnabled) { onAction(item.0) }
  }
  private func compactPreview(width: Float, triggerWidth: Float) -> some View {
    let left = [3, 4, 5].contains(selected), right = [6, 7, 8].contains(selected)
    let top = selected < 3
    let x: Float = left ? max(0, width - triggerWidth) : right ? 0 : max(0, (width - triggerWidth) / 2)
    let y: Float = top ? 130 : left || right ? 55 : 0
    return Box {
      Box(direction: .row, justifyContent: left ? .flexEnd : right ? .flexStart : .center) {
        preview(selected)
      }.frame(width: triggerWidth).absolutePosition(left: x, top: y)
    }.frame(height: 180)
  }
}
