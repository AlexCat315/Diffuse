#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EditorCore
import EngineKernel
import Foundation
import CoveUI
import CoveUIRuntime
import SceneRuntime

struct InspectorPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter
    private let sectionFilter: Set<String>?
    private var scripts: Observed<ScriptWorkspaceModel, ScriptWorkspaceSnapshot>?
    private let onOpenScript: ((String) -> Void)?
    private let sessionState: InspectorPanelSessionState
    @State private var searchText: TextBuffer
    @State private var expandedAdvancedFieldIDs: Set<String>

    init(store: EditorStore, scene: EditorSceneAdapter, sectionFilter: Set<String>? = nil,
         scriptWorkspace: ScriptWorkspaceModel? = nil, onOpenScript: ((String) -> Void)? = nil) {
        self.store = store
        self.scene = scene
        self.sectionFilter = sectionFilter
        self.scripts = scriptWorkspace.map { Observed(\.snapshot, on: $0) }
        self.onOpenScript = onOpenScript
        let sessionState = InspectorPanelSessionRegistry.state(for: store,
            scope: sectionFilter?.sorted().joined(separator: ",") ?? "inspector")
        self.sessionState = sessionState
        _searchText = State(wrappedValue: TextBuffer(sessionState.searchText))
        _expandedAdvancedFieldIDs = State(wrappedValue: sessionState.expandedAdvancedFieldIDs)
    }

    var body: some View {
        StoreScope(store) { store in
            let _ = store.sceneRevision
            let _ = store.uiRefreshRevision
            let _ = scripts?.wrappedValue
            let selectedEntityID = store.selectedEntityID
            let selectedEntityIDs = store.selectedEntityIDs.isEmpty
                ? Set(selectedEntityID.map { [$0] } ?? []) : store.selectedEntityIDs
            let entity = scene.entitySummary(id: selectedEntityID)
            let showingSceneSettings = sectionFilter == nil && store.inspectorSceneSettingsVisible
            let allSections = showingSceneSettings ? scene.sceneSettingsSections()
                : scene.inspectorSections(for: selectedEntityIDs, primaryID: selectedEntityID)
            let globalIDs: Set<String> = ["physics-settings", "particle-scalability"]
            let sections = allSections.filter {
                globalIDs.contains($0.id) == showingSceneSettings
                    && (sectionFilter?.contains($0.id) ?? true)
            }.map { scene.inspectorRenderers.presentedSection($0) }.sorted {
                Self.sectionPriority($0.id) < Self.sectionPriority($1.id)
            }
            let collapsedIDs = store.inspectorCollapsedSectionIDs
            let trimmedSearchText = searchText.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let filteredSections = InspectorSectionFilter.filter(sections, query: trimmedSearchText)
            let totalFieldCount = sections.reduce(0) { $0 + $1.fields.count }
            let visibleFieldCount = filteredSections.reduce(0) { $0 + $1.fields.count }
            let isAuthoringEnabled = EditorSceneAuthoringPolicy.canEditScene(
                during: store.playbackState
            )
            let canEditSelection = isAuthoringEnabled
                && (showingSceneSettings || (!selectedEntityIDs.isEmpty
                    && selectedEntityIDs.allSatisfy { !scene.isEntityLocked($0) }))
            let searchBinding = Binding<TextBuffer>(
                get: { searchText },
                set: updateSearchText
            )

            Box(direction: .column, alignItems: .stretch) {
                if let entity, !showingSceneSettings {
                    InspectorSelectionSummary(entity: entity,
                                              componentCount: scene.componentTypeIDs(on: entity.id).count,
                                              selectionCount: selectedEntityIDs.count,
                                              isLocked: scene.isEntityLocked(entity.id),
                                              isAuthoringEnabled: isAuthoringEnabled)
                }

                if showingSceneSettings {
                    Row(alignment: .center, spacing: 6) {
                        Text(L("Scene Settings")).font(.bodyStrong).flex()
                        Button(L("Return to Inspector")) { store.dispatch(.setInspectorSceneSettingsVisible(false)) }
                            .buttonStyle(.ghost)
                    }.padding(6)
                }

                if !sections.isEmpty {
                    EditorPanelSearchBar(
                        L("Search Properties"),
                        text: searchBinding,
                        // The count only answers a search; idle, it is noise.
                        summary: trimmedSearchText.isEmpty ? nil : "\(visibleFieldCount) / \(totalFieldCount)",
                        onCancel: { updateSearchText("") }
                    ) {
                        let hasExpanded = sections.contains { !collapsedIDs.contains($0.id) }
                        Button(icon: .resource(UIIcons.Navigation.chevronsUpDown),
                               size: 13,
                               isEnabled: trimmedSearchText.isEmpty && !sections.isEmpty,
                               tooltip: hasExpanded ? L("Collapse All") : L("Expand All")) {
                            setSections(sections, collapsed: hasExpanded)
                        }.buttonStyle(EditorChromeButtonStyle(height: 24))
                    }

                }

                if filteredSections.isEmpty {
                    EditorPanelEmptyState(
                        entity == nil && !showingSceneSettings ? L("Select an entity") : L("No matching properties"),
                        detail: trimmedSearchText.isEmpty
                            ? (sectionFilter == nil ? L("Choose an object in the viewport or Hierarchy to edit its properties.") : L("Select an entity with an animation component."))
                            : "\"\(trimmedSearchText)\""
                    )
                    .flex()
                } else {
                    PropertyGrid(propertySections(filteredSections,
                                                  collapsedIDs: trimmedSearchText.isEmpty
                                                    ? collapsedIDs
                                                    : [],
                                                  identity: showingSceneSettings ? "scene"
                                                    : selectedEntityIDs.sorted().map(String.init).joined(separator: ","),
                                                  isEditable: canEditSelection),
                                 labelWidth: 84,
                                 minValueWidth: 132,
                                 rowHeight: 24,
                                 rowSpacing: 3,
                                 sectionSpacing: 8,
                                 contentPadding: 8,
                                 scrollAxes: .vertical,
                                 emptyText: L("No properties"),
                                 collapsedSectionIDs: trimmedSearchText.isEmpty ? collapsedIDs : [],
                                 onSectionCollapseChanged: { id, isCollapsed in
                        store.dispatch(.setInspectorSectionCollapsed(id: id, isCollapsed: isCollapsed))
                    })
                        .flex()
                }
                if let entity, !showingSceneSettings, sectionFilter == nil {
                    ComponentActionsBar(store: store,
                                        scene: scene,
                                        entityIDs: selectedEntityIDs.isEmpty ? [entity.id] : selectedEntityIDs,
                                        isAuthoringEnabled: isAuthoringEnabled)
                }
                if let entity, sectionFilter != nil, !scene.componentTypeIDs(on: entity.id).contains("animationPlayer") {
                    Button(L("Add Animation Player"), isEnabled: canEditSelection) {
                        _ = scene.addComponent("animationPlayer", to: selectedEntityIDs.isEmpty ? [entity.id] : selectedEntityIDs)
                    }.buttonStyle(.ghost).padding(6)
                }
            }
            .frame(minWidth: 0, minHeight: 0)
        }
    }

    private static func sectionPriority(_ id: String) -> Int {
        switch id {
        case "transform": 0
        case "render-mesh": 1
        case "render-material": 2
        case "scripts": 3
        case "general": 90
        case "hierarchy": 91
        default: 10
        }
    }

    private func updateSearchText(_ value: TextBuffer) {
        sessionState.searchText = value.stringValue
        searchText = value
    }

    private func setSections(_ sections: [EditorInspectorSection], collapsed: Bool) {
        let advancedIDs = Set(sections.flatMap { section in
            section.fields.filter { $0.presentation == .advanced }.map { field in
                let owner = section.groups.first { $0.fieldIDs.contains(field.id) }?.id ?? section.id
                return "\(owner)/\(field.id)"
            }
        })
        var next = expandedAdvancedFieldIDs
        if collapsed { next.subtract(advancedIDs) } else { next.formUnion(advancedIDs) }
        sessionState.expandedAdvancedFieldIDs = next
        expandedAdvancedFieldIDs = next
        store.dispatch(.setInspectorSectionsCollapsed(
            ids: Set(sections.flatMap { [$0.id] + $0.groups.map(\.id) }),
            isCollapsed: collapsed
        ))
    }

    private struct InspectorSelectionSummary: View {
        let entity: EditorSceneEntitySummary
        let componentCount: Int
        let selectionCount: Int
        let isLocked: Bool
        let isAuthoringEnabled: Bool

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 6) {
                Row(alignment: .center, spacing: 8) {
                    Icon(UIIcons.Editor.box, size: 18, color: .accent)
                        .frame(width: 30, height: 30)
                        .background(.accentMuted).cornerRadius(7)
                    Box(direction: .column, alignItems: .stretch, spacing: 2) {
                        Text(entity.name)
                            .lineLimit(1)
                            .font(.bodyStrong)
                            .foregroundColor(.onSurface)

                        Text("\(entity.kind) · \(componentCount) \(L("Components"))")
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(.onSurfaceVariant)
                    }
                    .flex()
                    EditorPanelBadge("ID \(entity.id)")
                }

                if selectionCount > 1 || isLocked || !isAuthoringEnabled {
                    Row(alignment: .center, spacing: 6) {
                    if selectionCount > 1 {
                        EditorPanelBadge("\(selectionCount) \(L("selected"))",
                                         foreground: .accent)
                    }
                    if isLocked {
                        EditorPanelBadge(L("Locked"), foreground: .warning)
                    } else if !isAuthoringEnabled {
                        EditorPanelBadge(L("Read Only"), foreground: .warning)
                    }
                    Spacer(minLength: 0)
                    }
                }

                if selectionCount > 1 {
                    Text(L("Edit common properties for all selected entities. Different values show Mixed value."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }
            .padding(horizontal: 10, vertical: 10)
            .background(.surface)
        }
    }

    private struct InspectorReadOnlyValue: View {
        let text: String

        var body: some View {
            Row(alignment: .center, spacing: 0) {
                Text(text)
                    .lineLimit(1)
                    .font(.mono)
                    .foregroundColor(.onSurfaceVariant)
                    .flex()
            }
            .padding(horizontal: 4, vertical: 3)
            .clipped()
        }
    }


    private struct InspectorBooleanValue: View {
        let binding: Binding<Bool>

        var body: some View {
            Row(alignment: .center, spacing: 6) {
                Checkbox(isOn: binding)
                Text(binding.wrappedValue ? L("On") : L("Off"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)
                    .flex()
            }
        }
    }

    private struct InspectorNumberValue: View {
        let binding: Binding<Float>
        let minValue: Float?
        let maxValue: Float?
        let step: Float?
        var isMixed = false

        var body: some View {
            NumberField(value: binding,
                        decimals: step == 1 ? 0 : 2,
                        size: .small,
                        minValue: minValue,
                        maxValue: maxValue,
                        step: step,
                        showsStepper: false,
                        mixedValueLabel: isMixed ? L("Mixed value") : nil)
                .frame(minWidth: 96)
                .flex()
        }
    }

    private struct InspectorTextValue: View {
        let identity: String
        let binding: Binding<String>
        var isMixed = false

        var body: some View {
            // Draft-while-editing: model normalization (empty entity name →
            // fallback, clip lookups) must not rewrite the text mid-edit.
            CommitOnBlurTextField(identity: identity, text: binding, size: .small,
                                 mixedValueLabel: isMixed ? L("Mixed value") : nil)
                .flex()
                .clipped()
        }
    }

    private struct InspectorStringOptionsValue: View {
        let binding: Binding<String>
        let options: [EditorInspectorStringOption]
        @State private var isPresented: Bool = false

        var body: some View {
            Popover(isPresented: $isPresented, width: 230, surface: .content, overflow: .flip) {
                Row(alignment: .center, spacing: 5) {
                    Text(selectedLabel, lineLimit: 1)
                        .font(.caption)
                        .foregroundColor(.onSurface)
                        .flex()
                    Icon(UIIcons.Navigation.chevronDown, size: 8, color: .onSurfaceMuted)
                }
                .padding(horizontal: 8, vertical: 4)
                .background(.surfaceSunken)
                .cornerRadius(3)
            } content: {
                Menu(options.map { option in
                    .item(MenuItem(id: "string-option-\(option.value)",
                                   title: option.label,
                                   isSelected: option.value == binding.wrappedValue,
                                   action: { binding.wrappedValue = option.value }))
                }, width: 230, maxVisibleRows: 12, onItemActivated: {
                    isPresented = false
                })
            }
        }

        private var selectedLabel: String {
            options.first(where: { $0.value == binding.wrappedValue })?.label
                ?? "\(L("Missing")): \(binding.wrappedValue)"
        }
    }

    private struct InspectorActionValue: View {
        let title: String
        let isDestructive: Bool
        let action: () -> Void

        var body: some View {
            if isDestructive {
                Button(title, role: .destructive, action: action)
                    .buttonStyle(.destructive)
            } else {
                Button(title, action: action)
                    .buttonStyle(.secondary)
            }
        }
    }

    private struct InspectorVectorValue: View {
        let x: Binding<Float>
        let y: Binding<Float>
        let z: Binding<Float>
        var mixedAxes: Set<String> = []

        var body: some View {
            var field = Vec3Field(x: x, y: y, z: z, decimals: 2, size: .small,
                                  mixedAxes: mixedAxes, mixedValueLabel: L("Mixed value"))
            field.minimumAxisWidth = 56
            return field
                .flex(1, shrink: 1, basis: 0)
                .clipped()
        }
    }

    private struct InspectorColorValue: View {
        let binding: Binding<Color>

        var body: some View {
            ColorField(color: binding,
                       showAlpha: false,
                       showsInlineValues: true,
                       showsInlineChannels: false)
                .flex()
                .clipped()
        }
    }

    /// Registered as the `entity.reference` control; internal so the registry can build it.
    struct InspectorEntityReferenceValue: View {
        let binding: Binding<UInt64>
        let options: [EditorInspectorEntityOption]
        @State private var isPresented: Bool = false

        var body: some View {
            Popover(isPresented: $isPresented, width: 220, surface: .content, overflow: .flip) {
                Row(alignment: .center, spacing: 5) {
                    Text(selectedLabel, lineLimit: 1)
                        .font(.caption)
                        .foregroundColor(.onSurface)
                        .flex()
                    Icon(UIIcons.Navigation.chevronDown, size: 8, color: .onSurfaceMuted)
                }
                .padding(horizontal: 8, vertical: 4)
                .background(.surfaceSunken)
                .cornerRadius(3)
            } content: {
                Menu(options.map { option in
                    .item(MenuItem(
                        id: "entity-reference-\(option.id)",
                        title: "\(option.name) · \(option.id)",
                        isSelected: option.id == binding.wrappedValue,
                        action: { binding.wrappedValue = option.id }
                    ))
                }, width: 220, maxVisibleRows: 10, onItemActivated: {
                    isPresented = false
                })
            }
        }

        private var selectedLabel: String {
            guard let selected = options.first(where: { $0.id == binding.wrappedValue }) else {
                return "\(L("Missing Entity")) · \(binding.wrappedValue)"
            }
            return "\(selected.name) · \(selected.id)"
        }
    }



    private func propertySections(_ sections: [EditorInspectorSection],
                                  collapsedIDs: Set<String>,
                                  identity: String,
                                  isEditable: Bool) -> [PropertyGridSection] {
        /// `requiresDirectMatch` keeps search from unfolding every binding of a
        /// grouped form: only rows whose label or value matches stay expanded.
        func row(for field: EditorInspectorField, sectionID: String,
                 requiresDirectMatch: Bool = false) -> PropertyGridRow {
            let isAdvanced = field.presentation == .advanced
            let fieldID = "\(sectionID)/\(field.id)"
            let value = propertyValue(field, identity: "\(identity)/\(fieldID)", isEditable: isEditable)
            let expansion = Binding<Bool>(
                get: {
                    let query = searchText.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let directlyMatches = field.label.range(of: query, options: .caseInsensitive) != nil
                        || field.value.readOnlyDescription.range(of: query, options: .caseInsensitive) != nil
                    return (!query.isEmpty && (!requiresDirectMatch || directlyMatches))
                        || expandedAdvancedFieldIDs.contains(fieldID)
                },
                set: { expanded in
                    var next = expandedAdvancedFieldIDs
                    if expanded { next.insert(fieldID) } else { next.remove(fieldID) }
                    sessionState.expandedAdvancedFieldIDs = next
                    expandedAdvancedFieldIDs = next
                }
            )
            return PropertyGridRow(id: field.id,
                            label: isAdvanced ? "" : field.label,
                            rowHeight: field.value.preferredRowHeight(defaultHeight: 28),
                            layout: isAdvanced ? .fullWidth : field.value.preferredRowLayout,
                            sizing: isAdvanced ? .intrinsic : field.value.preferredRowSizing) {
                if isAdvanced {
                    // Advanced editors stay quiet: a caption-weight disclosure.
                    DisclosureGroup(isExpanded: expansion) { value } label: {
                        Text(field.label, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                        .debugName("inspector-advanced-\(fieldID)")
                } else {
                    value
                }
            }
        }

        func layoutSections(_ section: EditorInspectorSection) -> [PropertyGridSection] {
            let startsCollapsed = collapsedIDs.contains(section.id)
            let layout = section.componentTypeID.map { scene.inspectorRenderers.layout(forComponentTypeID: $0) }
                ?? .standard
            switch layout {
            case .scriptBindings:
                return InspectorScriptSectionLayout.sections(for: section, context: .init(
                    collapsedIDs: collapsedIDs,
                    startsCollapsed: startsCollapsed,
                    isEditable: isEditable,
                    isPaused: store.playbackState == .paused,
                    documents: scripts?.wrappedValue.documents ?? [],
                    onOpenScript: onOpenScript,
                    row: { field, sectionID in
                        row(for: field, sectionID: sectionID, requiresDirectMatch: true)
                    }))
            case .particleModules:
                return InspectorParticlePropertyLayout.sections(
                    for: section,
                    collapsedIDs: collapsedIDs,
                    parentStartsCollapsed: startsCollapsed,
                    rowBuilder: { field, sectionID in row(for: field, sectionID: sectionID) }
                )
            case .standard:
                return [
                    PropertyGridSection(
                        id: section.id,
                        title: section.title,
                        rows: section.fields.map { row(for: $0, sectionID: section.id) },
                        isCollapsible: true,
                        startsCollapsed: startsCollapsed
                    )
                ]
            }
        }
        // Each component card carries its own Reset / Remove menu.
        return sections.flatMap { section -> [PropertyGridSection] in
            var built = layoutSections(section)
            // Script cards carry their own menu (open, change, remove).
            if let typeID = section.componentTypeID, isEditable, let card = built.first,
               scene.inspectorRenderers.layout(forComponentTypeID: typeID) != .scriptBindings {
                built[0] = withComponentMenu(card, typeID: typeID)
            }
            return built
        }
    }

    private func withComponentMenu(_ section: PropertyGridSection, typeID: String) -> PropertyGridSection {
        let targets = store.selectedEntityIDs.isEmpty ? Set(store.selectedEntityID.map { [$0] } ?? []) : store.selectedEntityIDs
        let menu = InspectorComponentMenu(typeID: typeID, title: section.title,
                                          entityIDs: targets, scene: scene, store: store)
        let trailing = AnyView(Row(alignment: .center, spacing: 2) {
            if let existing = section.headerTrailing { existing }
            menu
        })
        return PropertyGridSection(id: section.id, title: section.title, rows: section.rows,
                                   isCollapsible: section.isCollapsible, startsCollapsed: section.startsCollapsed,
                                   children: section.children, headerLeading: section.headerLeading,
                                   headerTrailing: trailing, footer: section.footer, badge: section.badge,
                                   showsRowCount: section.showsRowCount)
    }

    private func propertyValue(_ field: EditorInspectorField, identity: String,
                               isEditable: Bool) -> AnyView {
        guard isEditable else {
            return AnyView(InspectorReadOnlyValue(text: field.isMixed
                ? L("Mixed value") : field.value.readOnlyDescription))
        }
        switch field.value {
        case .text, .number, .constrainedNumber, .vector3, .readOnly:
            return AnyView(fieldView(field.value, identity: identity,
                                     isMixed: field.isMixed, mixedAxes: field.mixedAxes))
        default:
            if field.isMixed {
                return AnyView(InspectorMixedValue(applyPrimaryValue: field.applyPrimaryValue) {
                    fieldView(field.value, identity: identity)
                })
            }
            return AnyView(fieldView(field.value, identity: identity))
        }
    }

    private struct InspectorMixedValue<Content: View>: View {
        @State private var isPresented = false
        let applyPrimaryValue: (() -> Void)?
        let content: () -> Content

        var body: some View {
            Popover(isPresented: $isPresented, width: 300, surface: .content, overflow: .flip) {
                Row(alignment: .center, spacing: 4) {
                    Text(L("Mixed value")).font(.caption).foregroundColor(.onSurfaceVariant).flex()
                    Icon(UIIcons.Navigation.chevronDown, size: 8, color: .onSurfaceMuted)
                }
                .padding(horizontal: 6, vertical: 4)
                .background(.surfaceSunken)
            } content: {
                Column(alignment: .leading, spacing: 8) {
                    Text(L("Apply to all selected entities")).font(.caption).foregroundColor(.onSurfaceVariant)
                    content()
                    if let applyPrimaryValue {
                        Button(L("Use primary value for all")) {
                            applyPrimaryValue(); isPresented = false
                        }.buttonStyle(.ghost)
                    }
                }
                .padding(8)
            }
        }
    }

    private func fieldView(_ value: EditorInspectorFieldValue,
                           identity: String, isMixed: Bool = false,
                           mixedAxes: Set<String> = []) -> some View {
        if let control = EditorInspectorFieldControlRegistry.builtIn.view(for: value, context: .init(
            identity: identity,
            colliderState: sessionState.colliderState(for: identity),
            entityOptions: value.entityOptions ?? [])) {
            return control
        }
        switch value {
        case let .readOnly(text):
            return AnyView(InspectorReadOnlyValue(text: text))
        case let .text(binding):
            return AnyView(InspectorTextValue(identity: identity, binding: binding, isMixed: isMixed))
        case let .stringOptions(binding, options):
            return AnyView(InspectorStringOptionsValue(binding: binding, options: options))
        case let .action(title, isDestructive, action):
            return AnyView(InspectorActionValue(title: title,
                                                isDestructive: isDestructive,
                                                action: action))
        case let .bool(binding):
            return AnyView(InspectorBooleanValue(binding: binding))
        case let .number(binding):
            return AnyView(InspectorNumberValue(binding: binding,
                                                minValue: nil,
                                                maxValue: nil,
                                               step: nil, isMixed: isMixed))
        case let .constrainedNumber(binding, min, max, step, _):
            return AnyView(InspectorNumberValue(binding: binding,
                                                minValue: min,
                                                maxValue: max,
                                               step: step, isMixed: isMixed))
        case let .vector3(x, y, z):
            return AnyView(InspectorVectorValue(x: x, y: y, z: z, mixedAxes: mixedAxes))
        case let .color(binding):
            return AnyView(InspectorColorValue(binding: binding))
        case let .json(binding, minHeight):
            return AnyView(InspectorJSONInput(text: binding, minHeight: minHeight,
                                     labels: JsonFieldLabels(format: L("Format"), revert: L("Revert"),
                                                             valid: L("Valid JSON"), empty: L("Empty saves as {}"),
                                                             expand: L("Expand JSON Editor"), apply: L("Apply"), cancel: L("Cancel"),
                                                             resize: L("Editor height")))
                .id(identity).debugName("inspector-json-\(identity)"))
        case .colliderShapeInstances, .entityReference, .particleCurve, .particleSubEmitters, .particleModuleStack:
            // Compound editors resolve through the control registry above; reaching
            // the switch means no control is registered for their ID.
            return AnyView(InspectorReadOnlyValue(text: value.readOnlyDescription))
        case let .asset(binding, acceptedKinds, placeholder):
            return AnyView(AssetRefField(value: assetRefBinding(binding),
                                         activePayload: activeAssetDropPayload,
                                         acceptedKinds: acceptedKinds,
                                         pickerOptions: assetPickerOptions(acceptedKinds: acceptedKinds),
                                         placeholder: placeholder))
        }
    }

    private var activeAssetDropPayload: Binding<AssetDropPayload?> {
        Binding(
            get: { [store] in
                store.activeAssetDrag.map {
                    let asset = EditorAssetCatalog.asset(for: $0.assetID)
                    return AssetDropPayload(id: $0.assetID,
                                            name: $0.displayName,
                                            subtitle: asset?.relativePath,
                                            kind: $0.kindLabel,
                                            previewPath: asset?.previewPath)
                }
            },
            set: { _ in }
        )
    }

    private func assetRefBinding(_ binding: Binding<EditorInspectorAssetRef?>) -> Binding<AssetRef?> {
        Binding(
            get: {
                binding.wrappedValue.map {
                    AssetRef(id: $0.id,
                             name: $0.name,
                             subtitle: $0.subtitle,
                             kind: $0.kind,
                             previewPath: $0.previewPath)
                }
            },
            set: { next in
                binding.wrappedValue = next.map {
                    EditorInspectorAssetRef(id: $0.id,
                                            name: $0.name,
                                            subtitle: $0.subtitle,
                                            kind: $0.kind,
                                            previewPath: $0.previewPath)
                }
            }
        )
    }

    private func assetPickerOptions(acceptedKinds: Set<String>) -> [AssetRef] {
        InspectorAssetPickerCache.options(acceptedKinds: acceptedKinds)
    }
}

enum InspectorSectionFilter {
    static func filter(_ sections: [EditorInspectorSection], query: String) -> [EditorInspectorSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sections }

        return sections.compactMap { section in
            if section.title.range(of: needle, options: .caseInsensitive) != nil {
                return section
            }

            let matchingGroups = section.groups.filter { $0.title.range(of: needle, options: .caseInsensitive) != nil }
            let groupFields = Set(matchingGroups.flatMap { $0.fieldIDs + [$0.enabledFieldID, $0.statusFieldID, $0.selectorFieldID] + $0.actionFieldIDs })
            let fields = section.fields.filter {
                groupFields.contains($0.id) || $0.label.range(of: needle, options: .caseInsensitive) != nil
                    || $0.value.readOnlyDescription.range(
                        of: needle,
                        options: .caseInsensitive
                    ) != nil
            }
            guard !fields.isEmpty else { return nil }
            let visibleIDs = Set(fields.map(\.id))
            let groups = section.groups.filter { group in
                matchingGroups.contains { $0.id == group.id } || group.fieldIDs.contains { visibleIDs.contains($0) }
                    || visibleIDs.contains(group.selectorFieldID) || visibleIDs.contains(group.statusFieldID)
            }
            let controlIDs = Set(groups.flatMap { [$0.enabledFieldID, $0.statusFieldID, $0.selectorFieldID] + $0.actionFieldIDs })
            let controls = section.fields.filter { controlIDs.contains($0.id) && !visibleIDs.contains($0.id) }
            var result = section
            result.fields = fields + controls
            result.groups = groups
            return result
        }
    }
}

/// Dock reconciliation can reconstruct the Inspector view after every scene
/// revision. Keep the user's active property query attached to the editor
/// session so editing a value or changing the primary selection does not erase
/// the investigation context.
private final class InspectorPanelSessionState {
    var searchText: String = ""
    var expandedAdvancedFieldIDs: Set<String> = []
    private var colliderStates: [String: InspectorColliderShapeEditorState] = [:]

    func colliderState(for identity: String) -> InspectorColliderShapeEditorState {
        if let state = colliderStates[identity] { return state }
        let state = InspectorColliderShapeEditorState()
        colliderStates[identity] = state
        return state
    }
}

private enum InspectorPanelSessionRegistry {
    private struct Key: Hashable { let store: ObjectIdentifier; let scope: String }
    nonisolated(unsafe) private static var states: [
        Key: InspectorPanelSessionState
    ] = [:]

    static func state(for store: EditorStore, scope: String = "inspector") -> InspectorPanelSessionState {
        let key = Key(store: ObjectIdentifier(store), scope: scope)
        if let existing = states[key] {
            return existing
        }
        let created = InspectorPanelSessionState()
        states[key] = created
        return created
    }
}

private enum InspectorAssetPickerCache {
    nonisolated(unsafe) private static var cachedSignature: String = ""
    nonisolated(unsafe) private static var cachedOptions: [String: [AssetRef]] = [:]

    static func options(acceptedKinds: Set<String>) -> [AssetRef] {
        let entries = EditorAssetCatalog.entries()
        let signature = entries.map {
            "\($0.id)|\($0.kind.sceneKindLabel)|\($0.name)|\($0.relativePath)|\($0.absolutePath)"
        }.joined(separator: "\n")
        let key = acceptedKinds.sorted().joined(separator: "|")

        if signature == cachedSignature, let hit = cachedOptions[key] {
            return hit
        }
        if signature != cachedSignature {
            cachedOptions.removeAll(keepingCapacity: true)
            cachedSignature = signature
        }

        let options = entries
            .filter { acceptedKinds.isEmpty || acceptedKinds.contains($0.kind.sceneKindLabel) }
            .sorted { lhs, rhs in
                lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            }
            .map {
                AssetRef(id: $0.id,
                         name: $0.name,
                         subtitle: $0.relativePath,
                         kind: $0.kind.sceneKindLabel,
                         previewPath: $0.previewPath)
            }
        cachedOptions[key] = options
        return options
    }
}

private extension EditorAsset {
    var previewPath: String? {
        kind.isTexture ? absolutePath : nil
    }
}

private extension EditorInspectorFieldValue {
    var readOnlyDescription: String {
        switch self {
        case let .readOnly(value): return value
        case let .text(binding): return binding.wrappedValue
        case let .stringOptions(binding, options):
            return options.first(where: { $0.value == binding.wrappedValue })?.label
                ?? binding.wrappedValue
        case let .action(title, _, _):
            return "\(title) · \(L("Unavailable while scene editing is disabled"))"
        case let .bool(binding): return binding.wrappedValue ? L("On") : L("Off")
        case let .number(binding), let .constrainedNumber(binding, _, _, _, _):
            return String(format: "%.3g", binding.wrappedValue)
        case let .vector3(x, y, z):
            return String(format: "%.3g, %.3g, %.3g",
                          x.wrappedValue, y.wrappedValue, z.wrappedValue)
        case let .color(binding):
            let value = binding.wrappedValue
            return String(format: "RGBA %.2f, %.2f, %.2f, %.2f",
                          value.r, value.g, value.b, value.a)
        case let .json(binding, _): return binding.wrappedValue
        case let .colliderShapeInstances(binding): return "\(binding.wrappedValue.count)"
        case let .entityReference(binding, options):
            return options.first(where: { $0.id == binding.wrappedValue })?.name
                ?? String(binding.wrappedValue)
        case let .particleCurve(binding): return String(describing: binding.wrappedValue)
        case let .particleSubEmitters(binding): return "\(binding.wrappedValue.count)"
        case let .particleModuleStack(binding): return "\(binding.wrappedValue.modules.count)"
        case let .asset(binding, _, placeholder):
            return binding.wrappedValue?.name ?? placeholder
        }
    }

    var preferredRowLayout: PropertyGridRowLayout {
        if let metrics = EditorInspectorFieldControlRegistry.builtIn.metrics(for: self) {
            return metrics.layout
        }
        switch self {
        case .json: return .fullWidth
        default: return .twoColumn
        }
    }

    var preferredRowSizing: PropertyGridRowSizing {
        if let metrics = EditorInspectorFieldControlRegistry.builtIn.metrics(for: self) {
            return metrics.sizing
        }
        switch self {
        case .json, .vector3: return .intrinsic
        default: return .fixed
        }
    }

    func preferredRowHeight(defaultHeight: Float) -> Float? {
        if let metrics = EditorInspectorFieldControlRegistry.builtIn.metrics(for: self),
           let binding = erasedBinding {
            return metrics.height(binding, defaultHeight)
        }
        switch self {
        case .vector3:
            return max(defaultHeight, 30)
        case .asset:
            return max(defaultHeight, 34)
        default:
            return nil
        }
    }
}

/// The end of the card list: one way to add an optional component.
/// Reset and Remove live on each component card (`InspectorComponentMenu`);
/// structural components such as name and transform never offer them.
private struct ComponentActionsBar: View {
    let store: EditorStore
    let scene: EditorSceneAdapter
    let entityIDs: Set<UInt64>
    let isAuthoringEnabled: Bool
    @State private var isAddPresented: Bool = false

    var body: some View {
        // A bare Script component means nothing; scripts are added by choosing one.
        let addableKinds = scene.addableComponentSchemas(on: entityIDs).filter {
            scene.inspectorRenderers.layout(forComponentTypeID: $0.typeID) != .scriptBindings
        }
        let scripts = entityIDs.count == 1 ? scene.availableScriptOptions : []
        let containsLockedEntity = entityIDs.contains { scene.isEntityLocked($0) }
        let canAdd = isAuthoringEnabled && !containsLockedEntity && !entityIDs.isEmpty
            && !(addableKinds.isEmpty && scripts.isEmpty)
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if !isAuthoringEnabled {
                notice(L("Stop simulation to edit the scene"))
            } else if containsLockedEntity {
                notice(L("Selection contains locked entities — unlock them in Hierarchy to edit components"))
            } else {
                Popover(isPresented: $isAddPresented, isEnabled: canAdd, width: 280,
                        placement: .top, surface: .content, overflow: .flip,
                        onKey: { event, phase in
                            guard phase == .target || phase == .bubble,
                                  event.scancode == ComposeScancode.escape else { return .ignored }
                            isAddPresented = false
                            return .handled
                        }) {
                    Row(alignment: .center, spacing: 6) {
                        Icon(UIIcons.Action.plus, size: 12, color: canAdd ? .accent : .onSurfaceMuted)
                        Text(L("Add Component"), lineLimit: 1).font(.label)
                            .foregroundColor(canAdd ? .onSurface : .onSurfaceMuted)
                    }.padding(horizontal: 12).frame(height: .points(32))
                        .background(.surfaceRaised).cornerRadius(10)
                } content: {
                    InspectorComponentPicker(kinds: addableKinds, scripts: scripts, targetCount: entityIDs.count,
                                             isPresented: $isAddPresented, onSelect: { kind in
                        if !scene.addComponent(kind.typeID, to: entityIDs) {
                            store.dispatch(.appendConsoleMessage("Could not add component", severity: .error,
                                                                 detail: kind.displayName))
                        }
                    }, onSelectScript: { identifier in
                        guard let id = entityIDs.first, scene.addScriptBinding(to: id, identifier: identifier) else {
                            store.dispatch(.appendConsoleMessage("Could not add script", severity: .error,
                                                                 detail: identifier))
                            return
                        }
                    })
                }.debugName("inspector-add-component")
            }
        }
        .padding(EdgeInsets(leading: 8, bottom: 8, trailing: 8))
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.warning).padding(horizontal: 4, vertical: 4)
    }
}

/// One picker for everything an entity can gain: components by category,
/// then the project's scripts (each becomes its own component card).
private struct InspectorComponentPicker: View {
    let kinds: [ComponentSchema]
    var scripts: [EditorInspectorStringOption] = []
    let targetCount: Int
    let isPresented: Binding<Bool>
    let onSelect: (ComponentSchema) -> Void
    var onSelectScript: (String) -> Void = { _ in }
    @State private var searchText: TextBuffer = ""

    var body: some View {
        let filteredKinds = InspectorComponentFilter.filter(kinds, query: searchText.stringValue)
        let query = searchText.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredScripts = query.isEmpty ? scripts
            : scripts.filter { $0.label.range(of: query, options: .caseInsensitive) != nil }
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 6) {
                Text(L("Add Component"))
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                    .flex()
                EditorPanelBadge("\(targetCount) \(L(targetCount == 1 ? "entity" : "entities"))")
            }
            .padding(horizontal: 9, vertical: 7)

            EditorPanelSearchBar(L("Search Components"),
                                 text: $searchText,
                                 summary: "\(filteredKinds.count + filteredScripts.count)",
                                 onCancel: {
                if searchText.isEmpty {
                    isPresented.wrappedValue = false
                } else {
                    searchText = ""
                }
            })

            if filteredKinds.isEmpty && filteredScripts.isEmpty {
                EditorPanelEmptyState(L("No matching components"),
                                      detail: searchText.isEmpty ? nil : "\"\(searchText.stringValue)\"")
                    .frame(height: 110)
            } else {
                Menu(menuEntries(for: filteredKinds, scripts: filteredScripts),
                     width: 280,
                     maxVisibleRows: 15,
                     onItemActivated: { isPresented.wrappedValue = false })
            }
        }
    }

    private func menuEntries(for filteredKinds: [ComponentSchema],
                             scripts: [EditorInspectorStringOption]) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        for category in ComponentCategory.allCases {
            let categoryKinds = filteredKinds.filter { $0.category == category }
            guard !categoryKinds.isEmpty else { continue }
            if !entries.isEmpty {
                entries.append(.separator("component-category-\(category.rawValue)"))
            }
            entries.append(.item(MenuItem(
                id: "component-category-title-\(category.rawValue)",
                title: L(category.displayName),
                isEnabled: false,
                action: {}
            )))
            entries.append(contentsOf: categoryKinds.map { kind in
                .item(MenuItem(
                    id: "add-component-\(kind.typeID)",
                    title: L(kind.displayName),
                    action: { onSelect(kind) }
                ))
            })
        }
        if !scripts.isEmpty {
            if !entries.isEmpty { entries.append(.separator("component-category-scripts")) }
            entries.append(.label(id: "component-category-title-scripts", title: L("Scripts")))
            entries.append(contentsOf: scripts.map { option in
                .item(MenuItem(id: "add-script-\(option.value)", title: option.label,
                               action: { onSelectScript(option.value) }))
            })
        }
        return entries
    }
}

enum InspectorComponentFilter {
    static func filter(_ kinds: [ComponentSchema], query: String) -> [ComponentSchema] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return kinds }
        return kinds.filter { kind in
            kind.displayName.range(of: needle, options: .caseInsensitive) != nil
                || kind.typeID.range(of: needle, options: .caseInsensitive) != nil
                || kind.category.displayName.range(of: needle,
                                                             options: .caseInsensitive) != nil
        }
    }
}
