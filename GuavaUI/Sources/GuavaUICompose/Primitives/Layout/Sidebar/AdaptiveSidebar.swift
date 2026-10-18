private import Foundation
private import GuavaUIRuntime

/// One navigation tree and one content tree across sidebar, rail and drawer layouts.
/// Breakpoints use this container's allocation. Optional presentation belongs to
/// the caller's session and survives a temporary return to the expanded layout.
public struct AdaptiveSidebar<ID: Hashable, Header: View, Footer: View, Content: View>: View {
  private let title: String
  private let presentation: Binding<Bool>?
  private let selection: Binding<ID?>
  private let width: Binding<Float>?
  private let sections: [SidebarSection<ID>]
  private let options: AdaptiveSidebarOptions
  private let header: Header
  private let footer: Footer
  private let content: Content
  @State private var localPresentation = false
  @State private var focus = SidebarFocusHandoff()

  public init(
    _ title: String, isPresented: Binding<Bool>? = nil, selection: Binding<ID?>, width: Binding<Float>? = nil,
    sections: [SidebarSection<ID>], configure: (inout AdaptiveSidebarOptions) -> Void = { _ in },
    @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    presentation = isPresented
    self.selection = selection
    self.width = width
    self.sections = sections
    var options = AdaptiveSidebarOptions()
    configure(&options)
    options.layout.validate()
    options.resizing.validate()
    self.options = options
    self.header = header()
    self.footer = footer()
    self.content = content()
  }

  public var body: some View {
    SurfaceReader { surface in
      ContainerSizeReader { size in
        let geometry = SidebarGeometry(
          width: size.width > 0 ? Float(size.width) : surface.viewport.width,
          policy: options.layout, isPresented: isPresented.wrappedValue,
          requestedWidth: width?.wrappedValue, resizing: options.resizing,
          handleExtent: surface.input.contains(.touch) ? surface.minimumControlExtent : 7)
        SidebarShellHost(geometry: geometry, focus: focus) {
          HorizontalSwipeHost(
            onSwipe: { if $0 == .right { isPresented.wrappedValue = true } },
            isEnabled: options.allowsEdgeSwipe && surface.input.contains(.touch)
              && geometry.mode == .compact && !geometry.isModal,
            shouldBegin: { event, node in
              let x = CGFloat(event.x) - node.absoluteFrame.minX
              return x >= 0 && x < 24
            }
          ) {
            Box(direction: .rowReverse, alignItems: .stretch) {
              Box(direction: .column, alignItems: .stretch) {
                AnimatedVisibility(
                  isVisible: geometry.mode == .compact, transition: .identity, retainsContent: true
                ) {
                  Box(direction: .row, alignItems: .center) {
                    SidebarTrigger(focus: focus) { openButton }
                  }.padding(horizontal: 12, vertical: 4).background(.surface)
                }.flex(0, shrink: 0)
                content.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
              }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
              SidebarResizeHandle(value: width, extent: geometry.resizeHandleWidth,
                                  range: geometry.resizeRange, viewport: geometry.viewportWidth,
                                  resolvedWidth: geometry.dockedWidth,
                                  label: options.resizing.label, focus: focus)
              SidebarLayer(
                geometry: geometry, focus: focus, dismissal: options.drawer.dismissal,
                onDismiss: { isPresented.wrappedValue = false }
              ) {
                AnimatedVisibility(
                  isVisible: geometry.isModal, transition: .opacity, retainsContent: true
                ) {
                  SidebarBackdrop(dismissal: options.drawer.dismissal) {
                    isPresented.wrappedValue = false
                  }
                }.frame(width: .points(geometry.viewportWidth), height: .percent(100))
                  .absolutePosition(left: 0, top: 0)
                AnimatedVisibility(
                  isVisible: geometry.isVisible,
                  transition: geometry.mode == .expanded
                    ? .identity : .move(edge: .leading, distance: geometry.panelWidth),
                  retainsContent: true
                ) {
                  navigation(geometry).flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
                }.frame(width: .points(geometry.panelWidth), height: .percent(100))
                  .absolutePosition(left: 0, top: 0)
              }.frame(width: geometry.dockedWidth).flex(0, shrink: 0).zIndex(100)
            }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
          }.flex(1, shrink: 1, basis: 0)
        }.flex(1, shrink: 1, basis: 0)
      }.flex(1, shrink: 1)
    }
  }

  private var isPresented: Binding<Bool> { presentation ?? $localPresentation }

  private var openButton: some View {
    Button(icon: .resource(UIIcons.Layout.panelLeft), tooltip: options.openLabel) {
      focus.focusOpener(label: options.openLabel)
      isPresented.wrappedValue = true
    }
    .buttonStyle(.ghost).frame(minWidth: 44, minHeight: 44)
    .accessibility {
      $0.label = options.openLabel
      $0.state.isExpanded = isPresented.wrappedValue
    }
  }

  private func navigation(_ geometry: SidebarGeometry) -> some View {
    HorizontalSwipeHost(
      onSwipe: { if $0 == .left { isPresented.wrappedValue = false } },
      isEnabled: geometry.isModal && options.drawer.allowsSwipeDismissal
    ) {
      Sidebar(
        selection: selection, sections: sections,
        presentation: geometry.mode == .rail && !geometry.isModal
          ? .rail(showsLabels: options.layout.showsRailLabels) : .expanded,
        minimumRowHeight: geometry.mode == .expanded ? 38 : 44,
        onActivate: { _ in
          if geometry.isModal && options.drawer.closesOnSelection {
            isPresented.wrappedValue = false
          }
        },
        header: {
          Box(direction: .column, alignItems: .stretch) {
            AnimatedVisibility(
              isVisible: geometry.mode == .rail && !geometry.isModal, transition: .identity,
              retainsContent: true
            ) {
              openButton
            }
            AnimatedVisibility(
              isVisible: geometry.isModal, transition: .identity, retainsContent: true
            ) {
              Box(direction: .row, alignItems: .center, spacing: 8) {
                Text(title).font(.bodyStrong).flex(1, shrink: 1).frame(minWidth: 0)
                Button(icon: .resource(UIIcons.Action.x), tooltip: options.drawer.closeLabel) {
                  isPresented.wrappedValue = false
                }
                .buttonStyle(.ghost).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(options.drawer.closeLabel).flex(0, shrink: 0)
              }.padding(horizontal: 12, vertical: 8)
            }
            header
          }
        }, footer: { footer }
      ).flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
    }.accessibility {
      $0.role = geometry.isModal ? .dialog : .group
      $0.label = title
    }
  }
}

extension AdaptiveSidebar where Header == EmptyView, Footer == EmptyView {
  public init(
    _ title: String, isPresented: Binding<Bool>? = nil, selection: Binding<ID?>, width: Binding<Float>? = nil,
    sections: [SidebarSection<ID>], configure: (inout AdaptiveSidebarOptions) -> Void = { _ in },
    @ViewBuilder content: () -> Content
  ) {
    self.init(
      title, isPresented: isPresented, selection: selection, width: width, sections: sections,
      configure: configure,
      header: { EmptyView() }, footer: { EmptyView() }, content: content)
  }
}
