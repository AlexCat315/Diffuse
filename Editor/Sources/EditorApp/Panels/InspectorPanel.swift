#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

private struct InspectorParticleRuntimeDiagnostics {
    let frameStats: ParticleFrameStatsResource
    let scalability: ParticleScalabilityStateResource
    let renderStats: RenderFrameStats
    let eventReport: ParticleSimulationEventApplyReport
    let selectedEntityID: UInt64?
    let selectedGPUSimulationPlan: ParticleGPUSimulationPlan?
    let moduleValidationIssues: [ParticleModuleIssue]

    static let empty = InspectorParticleRuntimeDiagnostics(
        frameStats: .empty,
        scalability: .default,
        renderStats: .init(),
        eventReport: .empty,
        selectedEntityID: nil,
        selectedGPUSimulationPlan: nil,
        moduleValidationIssues: []
    )

    var selectedFrameStats: ParticleEmitterFrameStats? {
        frameStats.emitterStats(for: selectedEntityID)
    }

    var selectedEventStats: ParticleEmitterFrameStats? {
        eventReport.emitterStats(for: selectedEntityID)
    }

    var statsScopeLabel: String {
        selectedFrameStats != nil ? L("Selected") : L("Scene")
    }

    var liveParticleCount: Int {
        selectedFrameStats?.liveParticleCount ?? frameStats.liveParticleCount
    }

    var spawnedParticleCount: Int {
        selectedFrameStats?.spawnedParticleCount ?? frameStats.spawnedParticleCount
    }

    var capacityLimitedSpawnCount: Int {
        selectedFrameStats?.capacityLimitedSpawnCount ?? frameStats.capacityLimitedSpawnCount
    }

    var collisionCount: Int {
        selectedFrameStats?.collisionCount ?? frameStats.collisionCount
    }

    var expiredParticleCount: Int {
        selectedFrameStats?.expiredParticleCount ?? frameStats.expiredParticleCount
    }

    var subEmitterSpawnedCount: Int {
        selectedEventStats?.subEmitterSpawnedCount
            ?? selectedFrameStats?.subEmitterSpawnedCount
            ?? eventReport.subEmitterSpawnedCount
    }

    var eventCapacityLimitedSpawnCount: Int {
        selectedEventStats?.capacityLimitedSpawnCount ?? eventReport.capacityLimitedSpawnCount
    }

    var hasGPUSimulationWork: Bool {
        renderStats.gpuParticleSimulationBatchCount > 0
            || renderStats.gpuParticleSimulationParticleCount > 0
            || renderStats.gpuParticleSimulationDispatchWorkgroups > 0
    }

    var hasGPUEventPressure: Bool {
        eventReport.droppedReadbackEventCount > 0
            || renderStats.gpuParticleSimulationEventCapacity > 0
            || eventReport.totalReadbackEventCount > 0
    }

    func validationIssues(for moduleID: String) -> [ParticleModuleIssue] {
        moduleValidationIssues.filter { $0.moduleID == moduleID }
    }
}

struct InspectorPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter
    let renderStatsProvider: () -> RenderFrameStats
    let particleEventReportProvider: () -> ParticleSimulationEventApplyReport

    init(store: EditorStore,
         scene: EditorSceneAdapter,
         renderStatsProvider: @escaping () -> RenderFrameStats = { .init() },
         particleEventReportProvider: @escaping () -> ParticleSimulationEventApplyReport = { .empty }) {
        self.store = store
        self.scene = scene
        self.renderStatsProvider = renderStatsProvider
        self.particleEventReportProvider = particleEventReportProvider
    }

    var body: some View {
        StoreScope(store) { store in
            let _ = store.sceneRevision
            let _ = store.frameTimingRevision
            let selectedEntityID = store.selectedEntityID
            let entity = scene.entitySummary(id: selectedEntityID)
            let sections = scene.inspectorSections(for: selectedEntityID)
            let collapsedIDs = store.inspectorCollapsedSectionIDs
            let particleDiagnostics = InspectorParticleRuntimeDiagnostics(
                frameStats: scene.currentParticleFrameStats(),
                scalability: scene.currentParticleScalabilityState(),
                renderStats: renderStatsProvider(),
                eventReport: particleEventReportProvider(),
                selectedEntityID: selectedEntityID,
                selectedGPUSimulationPlan: scene.currentParticleGPUSimulationPlan(for: selectedEntityID),
                moduleValidationIssues: scene.currentParticleModuleValidationIssues(for: selectedEntityID)
            )

            Box(direction: .column, alignItems: .stretch) {
                if let entity {
                    InspectorSelectionSummary(entity: entity,
                                              componentCount: max(0, sections.count - 2))

                    AddComponentButton(scene: scene, entityID: entity.id)

                    PropertyGrid(propertySections(sections,
                                                  collapsedIDs: collapsedIDs,
                                                  entityID: selectedEntityID,
                                                  particleDiagnostics: particleDiagnostics),
                                 labelWidth: 108,
                                 minValueWidth: 132,
                                 rowHeight: 26,
                                 rowSpacing: 1,
                                 sectionSpacing: 6,
                                 contentPadding: 6,
                                 scrollAxes: .vertical,
                                 emptyText: L("No properties"),
                                 onSectionCollapseChanged: { id, isCollapsed in
                        store.dispatch(.setInspectorSectionCollapsed(id: id, isCollapsed: isCollapsed))
                    })
                        .flex()
                } else {
                    Box(direction: .column, alignItems: .stretch, spacing: 4) {
                        Text(L("No selection"))
                            .font(.bodyStrong)
                        Text(L("Select an entity in Hierarchy to inspect SceneRuntime components."))
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    .padding(10)
                }
            }
            .frame(minWidth: 300)
        }
    }

    private struct InspectorSelectionSummary: View {
        let entity: EditorSceneEntitySummary
        let componentCount: Int

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 6) {
                Row(alignment: .center, spacing: 8) {
                    Box(direction: .column, alignItems: .stretch, spacing: 2) {
                        Text(entity.name)
                            .lineLimit(1)
                            .font(.bodyStrong)
                            .foregroundColor(.onSurface)

                        Text(entity.kind)
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(.onSurfaceVariant)
                    }
                    .flex()

                }

                Row(alignment: .center, spacing: 6) {
                    Text(L("Components"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                    Text("\(componentCount)")
                        .font(.mono)
                        .foregroundColor(.onSurface)
                        .padding(horizontal: 6, vertical: 1)
                        .background(.surfaceVariant)
                        .cornerRadius(3)
                    Spacer(minLength: 0)
                }
            }
            .padding(horizontal: 9, vertical: 8)
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
            .padding(horizontal: 8, vertical: 5)
            .background(.surfaceSunken)
            .cornerRadius(7)
            .border(.border, width: 1)
            .clipped()
        }
    }

    private struct InspectorParticleModuleStackValue: View {
        private static let advancedModuleIDs: Set<String> = [
            "textureSheet",
            "trails",
            "subEmitters",
            "gpuSimulation",
        ]

        let binding: Binding<ParticleModuleStack>
        let diagnostics: InspectorParticleRuntimeDiagnostics

        private struct ModuleDiagnosticChip {
            let label: String
            let value: String
            let foreground: SemanticColorRef
            let background: SemanticColorRef

            init(_ label: String,
                 _ value: String,
                 foreground: SemanticColorRef = .onSurfaceVariant,
                 background: SemanticColorRef = .surface) {
                self.label = label
                self.value = value
                self.foreground = foreground
                self.background = background
            }
        }

        private enum ModuleRuntimeTone: Equatable {
            case muted
            case info
            case success
            case warning
            case error

            var foreground: SemanticColorRef {
                switch self {
                case .muted: return .onSurfaceMuted
                case .info: return .info
                case .success: return .success
                case .warning: return .warning
                case .error: return .error
                }
            }

            var background: SemanticColorRef {
                switch self {
                case .muted: return .surfaceSunken
                case .info: return .info.opacity(0.12)
                case .success: return .success.opacity(0.12)
                case .warning: return .warning.opacity(0.12)
                case .error: return .error.opacity(0.12)
                }
            }

            var accent: SemanticColorRef? {
                switch self {
                case .muted: return nil
                case .info: return .info
                case .success: return .success
                case .warning: return .warning
                case .error: return .error
                }
            }
        }

        private struct ModuleRuntimeStatus {
            let text: String
            let tone: ModuleRuntimeTone
        }

        private var stack: ParticleModuleStack {
            binding.wrappedValue
        }

        private var enabledModuleCount: Int {
            stack.modules.filter(\.isEnabled).count
        }

        private var advancedModuleCount: Int {
            stack.modules.filter { isAdvancedModule($0) }.count
        }

        private var coreModuleCount: Int {
            max(0, stack.modules.count - advancedModuleCount)
        }

        private var coreModuleIndices: [Int] {
            stack.modules.indices.filter { !isAdvancedModule(stack.modules[$0]) }
        }

        private var advancedModuleIndices: [Int] {
            stack.modules.indices.filter { isAdvancedModule(stack.modules[$0]) }
        }

        private var hasRepairableValidationIssues: Bool {
            var repaired = stack
            repaired.repairValidationIssues()
            return repaired != stack
        }

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                Box(direction: .column, alignItems: .stretch, spacing: 5) {
                    Row(alignment: .center, spacing: 8) {
                        Box(direction: .column, alignItems: .stretch, spacing: 1) {
                            Text(L("Module Stack"))
                                .lineLimit(1)
                                .font(.body)
                                .foregroundColor(.onSurface)
                            Text("\(stack.modules.count) \(L("modules")) · v\(stack.version)")
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                        }
                        .flex()

                        if hasRepairableValidationIssues {
                            Button(L("Repair"),
                                   tooltip: L("Clamp repairable particle module settings")) {
                                var stack = binding.wrappedValue
                                stack.repairValidationIssues()
                                binding.wrappedValue = stack
                            }
                            .buttonStyle(GhostButtonStyle())
                        }

                        Button(L("Reset"),
                               tooltip: L("Reset module order and enabled states")) {
                            var stack = binding.wrappedValue
                            stack.resetAuthoringState()
                            binding.wrappedValue = stack
                        }
                        .buttonStyle(GhostButtonStyle())
                    }

                    Row(alignment: .center, spacing: 5) {
                        summaryChip("\(L("Active")) \(enabledModuleCount)/\(stack.modules.count)",
                                    foreground: .onSurfaceVariant,
                                    background: .surfaceVariant)
                        summaryChip(validationSummaryStatus.text,
                                    foreground: validationSummaryStatus.tone.foreground,
                                    background: validationSummaryStatus.tone.background)
                        summaryChip("\(L("Core")) \(coreModuleCount)")
                        summaryChip("\(L("Advanced")) \(advancedModuleCount)")
                        summaryChip(diagnostics.statsScopeLabel)
                        summaryChip(gpuSummaryText,
                                    foreground: gpuSummaryForeground,
                                    background: gpuSummaryBackground)
                    }
                }
                .padding(horizontal: 2, vertical: 1)

                Box(direction: .column, alignItems: .stretch, spacing: 4) {
                    moduleGroup(title: L("Core"),
                                subtitle: "\(enabledCount(in: coreModuleIndices))/\(coreModuleIndices.count)",
                                indices: coreModuleIndices)

                    if !advancedModuleIndices.isEmpty {
                        moduleGroup(title: L("Advanced"),
                                    subtitle: "\(enabledCount(in: advancedModuleIndices))/\(advancedModuleIndices.count)",
                                    indices: advancedModuleIndices)
                    }
                }
            }
            .padding(horizontal: 8, vertical: 8)
            .background(.surfaceSunken)
            .cornerRadius(7)
            .border(.border, width: 1)
            .clipped()
        }

        private var gpuSummaryText: String {
            gpuSummaryStatus.text
        }

        private var validationSummaryStatus: ModuleRuntimeStatus {
            let errors = diagnostics.moduleValidationIssues.filter { $0.severity == .error }.count
            if errors > 0 {
                return ModuleRuntimeStatus(text: "\(errors) \(L("Errors"))", tone: .error)
            }
            let warnings = diagnostics.moduleValidationIssues.filter { $0.severity == .warning }.count
            if warnings > 0 {
                return ModuleRuntimeStatus(text: "\(warnings) \(L("Warnings"))", tone: .warning)
            }
            let info = diagnostics.moduleValidationIssues.filter { $0.severity == .info }.count
            if info > 0 {
                return ModuleRuntimeStatus(text: "\(info) \(L("Notes"))", tone: .info)
            }
            return ModuleRuntimeStatus(text: L("Clean"), tone: .success)
        }

        private var gpuSummaryStatus: ModuleRuntimeStatus {
            guard let module = stack.modules.first(where: { $0.id == "gpuSimulation" }),
                  module.isEnabled,
                  case let .gpuSimulation(settings) = module.settings else {
                return ModuleRuntimeStatus(text: L("GPU Off"), tone: .muted)
            }
            if diagnostics.eventReport.droppedReadbackEventCount > 0 {
                return ModuleRuntimeStatus(text: L("GPU Dropping"), tone: .warning)
            }
            if diagnostics.hasGPUSimulationWork {
                return ModuleRuntimeStatus(text: L("GPU Active"), tone: .success)
            }
            if let plan = diagnostics.selectedGPUSimulationPlan {
                switch plan.status {
                case .disabled:
                    return ModuleRuntimeStatus(text: L("GPU Off"), tone: .muted)
                case .supported:
                    return ModuleRuntimeStatus(text: L("GPU Ready"), tone: .success)
                case .fallbackToCPU:
                    return ModuleRuntimeStatus(text: L("CPU Fallback"), tone: .warning)
                case .requiredButUnsupported:
                    return ModuleRuntimeStatus(text: L("GPU Blocked"), tone: .warning)
                }
            }
            switch settings.simulationBackend {
            case .cpu:
                return ModuleRuntimeStatus(text: L("GPU Off"), tone: .muted)
            case .gpuIfSupported:
                return ModuleRuntimeStatus(text: L("GPU Preferred"), tone: .info)
            case .gpuRequired:
                return ModuleRuntimeStatus(text: L("GPU Required"), tone: .warning)
            }
        }

        private var gpuSummaryForeground: SemanticColorRef {
            gpuSummaryStatus.tone.foreground
        }

        private var gpuSummaryBackground: SemanticColorRef {
            gpuSummaryStatus.tone.background
        }

        private func summaryChip(_ text: String,
                                 foreground: SemanticColorRef = .onSurfaceMuted,
                                 background: SemanticColorRef = .surface) -> some View {
            Text(text)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(foreground)
                .padding(horizontal: 6, vertical: 2)
                .background(background)
                .cornerRadius(3)
        }

        private func moduleGroup(title: String, subtitle: String, indices: [Int]) -> AnyView {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 4) {
                Row(alignment: .center, spacing: 6) {
                    Text(title.uppercased())
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)

                    Text(subtitle)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .padding(horizontal: 5, vertical: 1)
                        .background(.surface)
                        .cornerRadius(3)

                    Spacer(minLength: 0)
                        .flex()
                }
                .padding(horizontal: 3, vertical: 2)

                Box(direction: .column, alignItems: .stretch, spacing: 3) {
                    for index in indices {
                        moduleRow(index, groupIndices: indices)
                    }
                }
            })
        }

        private func moduleRow(_ index: Int, groupIndices: [Int]) -> AnyView {
            let module = stack.modules[index]
            let localIndex = groupIndices.firstIndex(of: index) ?? 0
            let status = moduleStatus(module)
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 6) {
                Row(alignment: .center, spacing: 8) {
                    Spacer(minLength: 0)
                        .frame(width: 3, height: module.isExpanded ? 36 : 31)
                        .background(moduleAccent(module))
                        .cornerRadius(2)
                        .opacity(module.isEnabled ? 1 : 0.45)

                    Button(icon: .resource(module.isExpanded ? UICommonIcons.chevronDown : UICommonIcons.chevronRight),
                           size: 9,
                           tooltip: module.isExpanded ? L("Collapse module") : L("Expand module")) {
                        toggleModuleExpanded(index)
                    }
                    .frame(width: 24)
                    .buttonStyle(GhostButtonStyle())

                    Box(direction: .column, alignItems: .stretch, spacing: 2) {
                        Row(alignment: .center, spacing: 6) {
                            badge(module.stage.rawValue.uppercased())

                            Text(module.displayName)
                                .lineLimit(1)
                                .font(.body)
                                .foregroundColor(module.isEnabled ? .onSurface : .onSurfaceMuted)
                                .flex()

                            if let status {
                                badge(status.text,
                                      foreground: status.tone.foreground,
                                      background: status.tone.background)
                            }
                        }

                        Text(moduleDetail(module.settings))
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(module.isEnabled ? .onSurfaceVariant : .onSurfaceMuted)
                    }
                    .flex()
                    .opacity(module.isEnabled ? 1 : 0.62)

                    Toggle(isOn: moduleEnabledBinding(index))
                        .frame(width: 42)

                    Row(alignment: .center, spacing: 0) {
                        Button(icon: .resource(UICommonIcons.chevronUp),
                               size: 8,
                               isEnabled: localIndex > 0,
                               tooltip: L("Move module up")) {
                            moveModuleWithinGroup(groupIndices, localIndex: localIndex, offset: -1)
                        }
                        .frame(width: 18)
                        .buttonStyle(GhostButtonStyle())

                        Button(icon: .resource(UICommonIcons.chevronDown),
                               size: 8,
                               isEnabled: localIndex < groupIndices.count - 1,
                               tooltip: L("Move module down")) {
                            moveModuleWithinGroup(groupIndices, localIndex: localIndex, offset: 1)
                        }
                        .frame(width: 18)
                        .buttonStyle(GhostButtonStyle())
                    }
                    .frame(width: 36)
                }

                if module.isExpanded {
                    expandedModuleEditor(index: index, module: module)
                }
            }
            .padding(horizontal: 6, vertical: 6)
            .background(moduleBackground(module))
            .cornerRadius(5)
            .border(moduleBorder(module), width: 1))
        }

        private func isAdvancedModule(_ module: ParticleEmitterModule) -> Bool {
            Self.advancedModuleIDs.contains(module.id)
        }

        private func enabledCount(in indices: [Int]) -> Int {
            indices.filter { stack.modules.indices.contains($0) && stack.modules[$0].isEnabled }.count
        }

        private func moduleEnabledBinding(_ index: Int) -> Binding<Bool> {
            Binding(
                get: { binding.wrappedValue.modules.indices.contains(index)
                    ? binding.wrappedValue.modules[index].isEnabled
                    : false },
                set: { next in
                    var stack = binding.wrappedValue
                    guard stack.modules.indices.contains(index),
                          stack.modules[index].isEnabled != next else { return }
                    stack.modules[index].isEnabled = next
                    binding.wrappedValue = stack
                }
            )
        }

        private func badge(_ text: String,
                           foreground: SemanticColorRef = .onSurfaceMuted,
                           background: SemanticColorRef = .surfaceSunken) -> some View {
            Text(text)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(foreground)
                .padding(horizontal: 5, vertical: 1)
                .background(background)
                .cornerRadius(3)
        }

        private func moduleStatus(_ module: ParticleEmitterModule) -> ModuleRuntimeStatus? {
            guard module.isEnabled else {
                return ModuleRuntimeStatus(text: L("Off"), tone: .muted)
            }
            let validationIssues = diagnostics.validationIssues(for: module.id)
            if validationIssues.contains(where: { $0.severity == .error }) {
                return ModuleRuntimeStatus(text: L("Error"), tone: .error)
            }
            if validationIssues.contains(where: { $0.severity == .warning }) {
                return ModuleRuntimeStatus(text: L("Warn"), tone: .warning)
            }

            switch module.settings {
            case .emission:
                if diagnostics.capacityLimitedSpawnCount > 0 {
                    return ModuleRuntimeStatus(text: L("Dropping"), tone: .warning)
                }
                if diagnostics.spawnedParticleCount > 0 {
                    return ModuleRuntimeStatus(text: L("Spawning"), tone: .success)
                }
                if diagnostics.liveParticleCount > 0 {
                    return ModuleRuntimeStatus(text: L("Live"), tone: .info)
                }
                return nil
            case .shape, .velocity, .forces:
                if diagnostics.spawnedParticleCount > 0 {
                    return ModuleRuntimeStatus(text: L("Active"), tone: .success)
                }
                if diagnostics.liveParticleCount > 0 {
                    return ModuleRuntimeStatus(text: L("Live"), tone: .info)
                }
                return nil
            case .collision:
                if diagnostics.collisionCount > 0 {
                    return ModuleRuntimeStatus(text: L("Hits"), tone: .success)
                }
                return nil
            case .appearance:
                if diagnostics.capacityLimitedSpawnCount > 0 || diagnostics.scalability.pressure > 0 {
                    return ModuleRuntimeStatus(text: L("Scaled"), tone: .warning)
                }
                if diagnostics.expiredParticleCount > 0 {
                    return ModuleRuntimeStatus(text: L("Aging"), tone: .info)
                }
                return nil
            case .textureSheet:
                if diagnostics.renderStats.gpuParticleSortItemCount > 0 {
                    return ModuleRuntimeStatus(text: L("Sorting"), tone: .info)
                }
                return nil
            case .renderer:
                if diagnostics.renderStats.gpuParticleRenderInstanceCount > 0 {
                    return ModuleRuntimeStatus(text: L("Drawing"), tone: .success)
                }
                return nil
            case .trails:
                if diagnostics.renderStats.gpuParticleRenderInstanceCount > 0 {
                    return ModuleRuntimeStatus(text: L("Rendering"), tone: .success)
                }
                return nil
            case .subEmitters:
                if diagnostics.eventCapacityLimitedSpawnCount > 0 {
                    return ModuleRuntimeStatus(text: L("Dropping"), tone: .warning)
                }
                if diagnostics.subEmitterSpawnedCount > 0 {
                    return ModuleRuntimeStatus(text: L("Spawned"), tone: .success)
                }
                if diagnostics.eventReport.eventCount > 0 {
                    return ModuleRuntimeStatus(text: L("Events"), tone: .info)
                }
                return nil
            case let .gpuSimulation(settings):
                if diagnostics.eventReport.droppedReadbackEventCount > 0 {
                    return ModuleRuntimeStatus(text: L("Dropping"), tone: .warning)
                }
                if diagnostics.hasGPUSimulationWork {
                    return ModuleRuntimeStatus(text: L("Active"), tone: .success)
                }
                if let plan = diagnostics.selectedGPUSimulationPlan {
                    switch plan.status {
                    case .disabled:
                        return ModuleRuntimeStatus(text: L("CPU"), tone: .muted)
                    case .supported:
                        return ModuleRuntimeStatus(text: L("Ready"), tone: .success)
                    case .fallbackToCPU:
                        return ModuleRuntimeStatus(text: L("Fallback"), tone: .warning)
                    case .requiredButUnsupported:
                        return ModuleRuntimeStatus(text: L("Blocked"), tone: .warning)
                    }
                }
                switch settings.simulationBackend {
                case .cpu:
                    return ModuleRuntimeStatus(text: L("CPU"), tone: .muted)
                case .gpuIfSupported:
                    return ModuleRuntimeStatus(text: L("Preferred"), tone: .info)
                case .gpuRequired:
                    return ModuleRuntimeStatus(text: L("Waiting"), tone: .warning)
                }
            }
        }

        private func moduleAccent(_ module: ParticleEmitterModule) -> SemanticColorRef {
            guard module.isEnabled else { return .divider }
            if let accent = moduleStatus(module)?.tone.accent {
                return accent
            }
            if module.id == "gpuSimulation", diagnostics.hasGPUSimulationWork {
                return .success
            }
            switch module.stage {
            case .spawn, .initialize:
                return .accent
            case .update:
                return .info
            case .render:
                return .accentSecondary
            case .event:
                return .warning
            case .simulation:
                return .success
            }
        }

        private func moduleBackground(_ module: ParticleEmitterModule) -> SemanticColorRef {
            if !module.isEnabled { return .surfaceSunken }
            if moduleStatus(module)?.tone == .error {
                return .error.opacity(0.08)
            }
            if moduleStatus(module)?.tone == .warning {
                return .warning.opacity(0.08)
            }
            return module.isExpanded ? .surfaceRaised : .surface
        }

        private func moduleBorder(_ module: ParticleEmitterModule) -> SemanticColorRef {
            if !module.isEnabled { return .divider }
            if moduleStatus(module)?.tone == .error {
                return .error
            }
            if moduleStatus(module)?.tone == .warning {
                return .warning
            }
            if moduleStatus(module)?.tone == .success {
                return module.isExpanded ? .success : .divider
            }
            return module.isExpanded ? .borderStrong : .divider
        }

        private func toggleModuleExpanded(_ index: Int) {
            var stack = binding.wrappedValue
            guard stack.modules.indices.contains(index) else { return }
            stack.modules[index].isExpanded.toggle()
            binding.wrappedValue = stack
        }

        private func moveModuleWithinGroup(_ groupIndices: [Int], localIndex: Int, offset: Int) {
            var stack = binding.wrappedValue
            let destinationLocalIndex = localIndex + offset
            guard groupIndices.indices.contains(localIndex),
                  groupIndices.indices.contains(destinationLocalIndex) else { return }
            let source = groupIndices[localIndex]
            let destination = groupIndices[destinationLocalIndex]
            guard stack.modules.indices.contains(source),
                  stack.modules.indices.contains(destination),
                  source != destination else { return }
            stack.modules.swapAt(source, destination)
            binding.wrappedValue = stack
        }

        private func expandedModuleEditor(index: Int, module: ParticleEmitterModule) -> AnyView {
            let issues = diagnostics.validationIssues(for: module.id)
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 7) {
                expandedModuleHeader(index: index, module: module)

                moduleEditor(index: index, module: module)

                if case .gpuSimulation = module.settings {
                    gpuBackendStatusPanel(module)
                }

                if !issues.isEmpty {
                    moduleIssueDetails(issues)
                }

                let chips = moduleDiagnosticChips(module)
                if !chips.isEmpty {
                    Box(direction: .column, alignItems: .stretch, spacing: 4) {
                        Text(L("Runtime"))
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                        Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 4) {
                            for chip in chips {
                                diagnosticChip(chip.label,
                                               chip.value,
                                               foreground: chip.foreground,
                                               background: chip.background)
                            }
                        }
                    }
                }
            }
            .padding(horizontal: 7, vertical: 7)
            .background(.surfaceSunken)
            .cornerRadius(4)
            .border(.divider, width: 1))
        }

        private func gpuBackendStatusPanel(_ module: ParticleEmitterModule) -> AnyView {
            let plan = diagnostics.selectedGPUSimulationPlan
            let status = plan.map(gpuPlanStatus) ?? moduleStatus(module) ?? ModuleRuntimeStatus(text: L("Unknown"),
                                                                                                tone: .muted)
            let dispatch = plan.map { "\($0.dispatchWorkgroups) x \($0.workgroupSize)" } ?? "--"
            let capacity = plan.map { "\($0.particleCapacity)" } ?? "--"
            let reason = plan.map { gpuPlanUnsupportedReasonList($0.unsupportedReasons) } ?? L("No plan")
            let reasonTone: ModuleRuntimeTone = plan?.unsupportedReasons.isEmpty == false ? .warning : .muted

            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 5) {
                Row(alignment: .center, spacing: 6) {
                    Text(L("Backend Runtime"))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Spacer(minLength: 0)
                        .flex()
                    badge(status.text,
                          foreground: status.tone.foreground,
                          background: status.tone.background)
                }

                Row(alignment: .center, spacing: 6) {
                    backendMetricCard(L("Capacity"), capacity, tone: .info)
                    backendMetricCard(L("Dispatch"), dispatch, tone: diagnostics.hasGPUSimulationWork ? .success : .muted)
                    backendMetricCard(L("Readback"),
                                      "\(diagnostics.eventReport.totalReadbackEventCount)",
                                      tone: diagnostics.hasGPUEventPressure ? .info : .muted)
                }

                Row(alignment: .center, spacing: 6) {
                    Text(L("Reason"))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Text(reason)
                        .lineLimit(2)
                        .font(.caption)
                        .foregroundColor(reasonTone.foreground)
                        .flex()
                }
            }
            .padding(horizontal: 6, vertical: 6)
            .background(status.tone.background)
            .cornerRadius(4)
            .border(status.tone.foreground.opacity(0.35), width: 1))
        }

        private func backendMetricCard(_ label: String,
                                       _ value: String,
                                       tone: ModuleRuntimeTone) -> AnyView {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 1) {
                Text(label)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Text(value)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(tone.foreground)
            }
            .padding(horizontal: 6, vertical: 4)
            .background(.surface)
            .cornerRadius(4)
            .border(tone.background, width: 1)
            .flex())
        }

        private func moduleIssueDetails(_ issues: [ParticleModuleIssue]) -> AnyView {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 4) {
                Text(L("Issues"))
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                for issue in issues {
                    moduleIssueDetailRow(issue)
                }
            })
        }

        private func moduleIssueDetailRow(_ issue: ParticleModuleIssue) -> AnyView {
            let tone = moduleIssueTone(issue.severity)
            return AnyView(Row(alignment: .center, spacing: 6) {
                badge(moduleIssueSeverityLabel(issue.severity),
                      foreground: tone.foreground,
                      background: tone.background)
                Text(issue.message)
                    .lineLimit(2)
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)
                    .flex()
            }
            .padding(horizontal: 5, vertical: 4)
            .background(tone.background)
            .cornerRadius(4))
        }

        private func expandedModuleHeader(index: Int, module: ParticleEmitterModule) -> AnyView {
            let status = moduleStatus(module)
            return AnyView(Row(alignment: .center, spacing: 8) {
                Spacer(minLength: 0)
                    .frame(width: 3, height: 42)
                    .background(moduleAccent(module))
                    .cornerRadius(2)
                    .opacity(module.isEnabled ? 1 : 0.45)

                Box(direction: .column, alignItems: .stretch, spacing: 3) {
                    Row(alignment: .center, spacing: 5) {
                        badge(module.stage.rawValue.uppercased(),
                              foreground: moduleAccent(module),
                              background: moduleAccent(module).opacity(0.10))
                        if let status {
                            badge(status.text,
                                  foreground: status.tone.foreground,
                                  background: status.tone.background)
                        }
                    }

                    Text(module.displayName)
                        .lineLimit(1)
                        .font(.body)
                        .foregroundColor(module.isEnabled ? .onSurface : .onSurfaceMuted)

                    Text(moduleDetail(module.settings))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(module.isEnabled ? .onSurfaceVariant : .onSurfaceMuted)
                }
                .flex()
                .opacity(module.isEnabled ? 1 : 0.66)

                Box(direction: .column, alignItems: .center, spacing: 3) {
                    Toggle(isOn: moduleEnabledBinding(index))
                    Text(module.isEnabled ? L("Enabled") : L("Disabled"))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(module.isEnabled ? .onSurfaceVariant : .onSurfaceMuted)
                }
                .frame(width: 58)
            }
            .padding(horizontal: 5, vertical: 5)
            .background(module.isEnabled ? .surface : .surfaceSunken)
            .cornerRadius(4))
        }

        private func moduleDiagnosticChips(_ module: ParticleEmitterModule) -> [ModuleDiagnosticChip] {
            let issueChips = moduleIssueChips(module)
            guard module.isEnabled else {
                return issueChips + [
                    ModuleDiagnosticChip(L("State"),
                                         L("Disabled"),
                                         foreground: .onSurfaceMuted,
                                         background: .surface),
                ]
            }
            let runtimeChips: [ModuleDiagnosticChip]
            switch module.settings {
            case .emission:
                runtimeChips = [
                    ModuleDiagnosticChip(L("Scope"), diagnostics.statsScopeLabel),
                    runtimeMetricChip(L("Live"), diagnostics.liveParticleCount, tone: .info),
                    runtimeMetricChip(L("Spawn"), diagnostics.spawnedParticleCount, tone: .success),
                    ModuleDiagnosticChip(L("Dropped"), "\(diagnostics.capacityLimitedSpawnCount)",
                                         foreground: diagnostics.capacityLimitedSpawnCount > 0 ? .warning : .onSurfaceVariant,
                                         background: diagnostics.capacityLimitedSpawnCount > 0 ? .warning.opacity(0.12) : .surface),
                ]
            case .collision:
                runtimeChips = [
                    ModuleDiagnosticChip(L("Scope"), diagnostics.statsScopeLabel),
                    runtimeMetricChip(L("Hits"), diagnostics.collisionCount, tone: .success),
                    runtimeMetricChip(L("Events"), diagnostics.eventReport.collisionEventCount, tone: .info),
                    ModuleDiagnosticChip(L("Bounce"), moduleCollisionBounce(module.settings)),
                ]
            case .appearance:
                runtimeChips = [
                    ModuleDiagnosticChip(L("Scope"), diagnostics.statsScopeLabel),
                    runtimeMetricChip(L("Expired"), diagnostics.expiredParticleCount, tone: .info),
                    ModuleDiagnosticChip(L("Scale"), fmt(diagnostics.scalability.appliedScale)),
                    ModuleDiagnosticChip(L("Pressure"), fmt(diagnostics.scalability.pressure),
                                         foreground: diagnostics.scalability.pressure > 1 ? .warning : .onSurfaceVariant,
                                         background: diagnostics.scalability.pressure > 1 ? .warning.opacity(0.12) : .surface),
                ]
            case .renderer:
                runtimeChips = [
                    runtimeMetricChip(L("Submitted"), diagnostics.renderStats.gpuParticleRenderInstanceCount, tone: .success),
                    runtimeMetricChip(L("Draws"), diagnostics.renderStats.gpuParticleIndirectDrawCount, tone: .success),
                    runtimeMetricChip(L("Cull"), diagnostics.renderStats.gpuParticleCullCandidateCount, tone: .info),
                ]
            case .textureSheet:
                runtimeChips = [
                    runtimeMetricChip(L("Sort"), diagnostics.renderStats.gpuParticleSortItemCount, tone: .info),
                    runtimeMetricChip(L("Passes"), diagnostics.renderStats.gpuParticleSortPassCount, tone: .info),
                ]
            case .trails:
                runtimeChips = [
                    ModuleDiagnosticChip(L("Scope"), diagnostics.statsScopeLabel),
                    runtimeMetricChip(L("Live"), diagnostics.liveParticleCount, tone: .info),
                    runtimeMetricChip(L("Render"), diagnostics.renderStats.gpuParticleRenderInstanceCount, tone: .success),
                ]
            case .subEmitters:
                runtimeChips = [
                    ModuleDiagnosticChip(L("Events"), "\(diagnostics.eventReport.appliedEventCount)/\(diagnostics.eventReport.eventCount)"),
                    ModuleDiagnosticChip(L("Scope"), diagnostics.statsScopeLabel),
                    runtimeMetricChip(L("Spawned"), diagnostics.subEmitterSpawnedCount, tone: .success),
                    ModuleDiagnosticChip(L("Dropped"), "\(diagnostics.eventCapacityLimitedSpawnCount)",
                                         foreground: diagnostics.eventCapacityLimitedSpawnCount > 0 ? .warning : .onSurfaceVariant,
                                         background: diagnostics.eventCapacityLimitedSpawnCount > 0 ? .warning.opacity(0.12) : .surface),
                ]
            case .gpuSimulation:
                runtimeChips = gpuSimulationDiagnostics()
            case .shape, .velocity, .forces:
                runtimeChips = [
                    ModuleDiagnosticChip(L("Scope"), diagnostics.statsScopeLabel),
                    runtimeMetricChip(L("Live"), diagnostics.liveParticleCount, tone: .info),
                    runtimeMetricChip(L("Spawn"), diagnostics.spawnedParticleCount, tone: .success),
                    ModuleDiagnosticChip(L("Frame"), formatMs(diagnostics.frameStats.simulatedDeltaTime)),
                ]
            }
            return issueChips + runtimeChips
        }

        private func gpuSimulationDiagnostics() -> [ModuleDiagnosticChip] {
            var chips: [ModuleDiagnosticChip] = []
            if let plan = diagnostics.selectedGPUSimulationPlan {
                let status = gpuPlanStatus(plan)
                chips.append(ModuleDiagnosticChip(L("Plan"),
                                                  status.text,
                                                  foreground: status.tone.foreground,
                                                  background: status.tone.background))
                chips.append(ModuleDiagnosticChip(L("Dispatch"),
                                                  "\(plan.dispatchWorkgroups)x\(plan.workgroupSize)"))
                if !plan.unsupportedReasons.isEmpty {
                    chips.append(ModuleDiagnosticChip(L("Reason"),
                                                      gpuPlanUnsupportedReasonList(plan.unsupportedReasons),
                                                      foreground: .warning,
                                                      background: .warning.opacity(0.12)))
                }
            }
            chips.append(contentsOf: [
                ModuleDiagnosticChip(L("Batches"), "\(diagnostics.renderStats.gpuParticleSimulationBatchCount)",
                                     foreground: diagnostics.hasGPUSimulationWork ? .success : .onSurfaceVariant,
                                     background: diagnostics.hasGPUSimulationWork ? .success.opacity(0.12) : .surface),
                runtimeMetricChip(L("Particles"), diagnostics.renderStats.gpuParticleSimulationParticleCount, tone: .success),
                runtimeMetricChip(L("Workgroups"), diagnostics.renderStats.gpuParticleSimulationDispatchWorkgroups, tone: .success),
                ModuleDiagnosticChip(L("Readback"), "\(diagnostics.eventReport.totalReadbackEventCount)",
                                     foreground: diagnostics.hasGPUEventPressure ? .info : .onSurfaceVariant,
                                     background: diagnostics.hasGPUEventPressure ? .info.opacity(0.12) : .surface),
                ModuleDiagnosticChip(L("Dropped"), "\(diagnostics.eventReport.droppedReadbackEventCount)",
                                     foreground: diagnostics.eventReport.droppedReadbackEventCount > 0 ? .warning : .onSurfaceVariant,
                                     background: diagnostics.eventReport.droppedReadbackEventCount > 0 ? .warning.opacity(0.12) : .surface),
                ModuleDiagnosticChip(L("Buffer"), "\(diagnostics.renderStats.gpuParticleSimulationEventBufferBytes)B"),
            ])
            return chips
        }

        private func gpuPlanStatus(_ plan: ParticleGPUSimulationPlan) -> ModuleRuntimeStatus {
            switch plan.status {
            case .disabled:
                return ModuleRuntimeStatus(text: L("CPU"), tone: .muted)
            case .supported:
                return ModuleRuntimeStatus(text: L("Ready"), tone: .success)
            case .fallbackToCPU:
                return ModuleRuntimeStatus(text: L("Fallback"), tone: .warning)
            case .requiredButUnsupported:
                return ModuleRuntimeStatus(text: L("Blocked"), tone: .warning)
            }
        }

        private func gpuPlanUnsupportedReasonList(_ reasons: [ParticleGPUSimulationUnsupportedReason]) -> String {
            guard !reasons.isEmpty else { return L("None") }
            return reasons.map(gpuPlanUnsupportedReasonLabel).joined(separator: ", ")
        }

        private func gpuPlanUnsupportedReasonLabel(_ reason: ParticleGPUSimulationUnsupportedReason) -> String {
            switch reason {
            case .backendCPU:
                return L("CPU backend")
            case .noParticleCapacity:
                return L("no capacity")
            case .eventSubEmitters:
                return L("sub-emitters")
            case .distanceEmission:
                return L("distance emission")
            case .noise:
                return L("noise")
            case .forceFields:
                return L("force fields")
            case .collisions:
                return L("collisions")
            case .angularVelocity:
                return L("angular velocity")
            }
        }

        private func diagnosticChip(_ label: String,
                                    _ value: String,
                                    foreground: SemanticColorRef,
                                    background: SemanticColorRef) -> AnyView {
            AnyView(Row(alignment: .center, spacing: 4) {
                Text(label)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Text(value)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(foreground)
            }
            .padding(horizontal: 6, vertical: 2)
            .background(background)
            .cornerRadius(3))
        }

        private func runtimeMetricChip(_ label: String,
                                       _ value: Int,
                                       tone: ModuleRuntimeTone = .info) -> ModuleDiagnosticChip {
            ModuleDiagnosticChip(label,
                                 "\(value)",
                                 foreground: value > 0 ? tone.foreground : .onSurfaceVariant,
                                 background: value > 0 ? tone.background : .surface)
        }

        private func moduleIssueChips(_ module: ParticleEmitterModule) -> [ModuleDiagnosticChip] {
            diagnostics.validationIssues(for: module.id).map { issue in
                let tone = moduleIssueTone(issue.severity)
                return ModuleDiagnosticChip(moduleIssueSeverityLabel(issue.severity),
                                            moduleIssueTitle(issue),
                                            foreground: tone.foreground,
                                            background: tone.background)
            }
        }

        private func moduleIssueTone(_ severity: ParticleModuleIssueSeverity) -> ModuleRuntimeTone {
            switch severity {
            case .info:
                return .info
            case .warning:
                return .warning
            case .error:
                return .error
            }
        }

        private func moduleIssueSeverityLabel(_ severity: ParticleModuleIssueSeverity) -> String {
            switch severity {
            case .info:
                return L("Info")
            case .warning:
                return L("Warn")
            case .error:
                return L("Error")
            }
        }

        private func moduleIssueTitle(_ issue: ParticleModuleIssue) -> String {
            switch issue.code {
            case "noParticleCapacity":
                return L("No Capacity")
            case "noSpawnSource":
                return L("No Spawn")
            case "invalidLifetime", "subEmitterInvalidLifetime":
                return L("Lifetime")
            case "invalidTextureSheet":
                return L("Sheet Size")
            case "frameCountExceedsCells":
                return L("Frame Count")
            case "gpuFallbackToCPU":
                return L("CPU Fallback")
            case "gpuRequiredButUnsupported":
                return L("GPU Blocked")
            case "invalidGPUWorkgroup":
                return L("Workgroup")
            case "gpuWorkgroupClamped":
                return L("Clamped")
            default:
                return issue.code
            }
        }

        private func moduleCollisionBounce(_ settings: ParticleEmitterModuleSettings) -> String {
            guard case let .collision(module) = settings else { return "--" }
            return fmt(module.collisionRestitution)
        }

        private func moduleEditor(index: Int, module: ParticleEmitterModule) -> AnyView {
            let isEnabled = module.isEnabled
            switch module.settings {
            case .emission:
                return AnyView(moduleEditorRow([
                    moduleNumber("Rate",
                                 moduleFloatBinding(index, fallback: 0, get: {
                                     if case let .emission(module) = $0 { return module.emissionRate }
                                     return nil
                                 }, set: {
                                     if case var .emission(module) = $0 {
                                         module.emissionRate = $1
                                         $0 = .emission(module)
                                     }
                                 }),
                                 min: 0,
                                 max: 1000,
                                 step: 1,
                                 enabled: isEnabled),
                    moduleNumber("Max",
                                 moduleIntBinding(index, fallback: 0, get: {
                                     if case let .emission(module) = $0 { return module.maxParticles }
                                     return nil
                                 }, set: {
                                     if case var .emission(module) = $0 {
                                         module.maxParticles = $1
                                         $0 = .emission(module)
                                     }
                                 }),
                                 min: 0,
                                 max: 100_000,
                                 step: 16,
                                 enabled: isEnabled),
                    moduleNumber("Burst",
                                 moduleIntBinding(index, fallback: 0, get: {
                                     if case let .emission(module) = $0 { return module.burstCount }
                                     return nil
                                 }, set: {
                                     if case var .emission(module) = $0 {
                                         module.burstCount = $1
                                         $0 = .emission(module)
                                     }
                                 }),
                                 min: 0,
                                 max: 100_000,
                                 step: 1,
                                 enabled: isEnabled),
                ]))
            case .shape:
                return AnyView(moduleEditorRows([
                    [
                        moduleEnum("Shape",
                                   moduleValueBinding(index, fallback: .sphere, get: {
                                       if case let .shape(module) = $0 { return module.emissionShape }
                                       return nil
                                   }, set: {
                                       if case var .shape(module) = $0 {
                                           module.emissionShape = $1
                                           $0 = .shape(module)
                                       }
                                   }),
                                   width: 132,
                                   enabled: isEnabled,
                                   label: particleEmissionShapeLabel),
                        moduleNumber("Radius",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .shape(module) = $0 { return module.spawnRadius }
                                         return nil
                                     }, set: {
                                         if case var .shape(module) = $0 {
                                             module.spawnRadius = $1
                                             $0 = .shape(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Origin X",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .shape(module) = $0 { return module.originOffset.x }
                                         return nil
                                     }, set: {
                                         if case var .shape(module) = $0 {
                                             module.originOffset.x = $1
                                             $0 = .shape(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Origin Y",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .shape(module) = $0 { return module.originOffset.y }
                                         return nil
                                     }, set: {
                                         if case var .shape(module) = $0 {
                                             module.originOffset.y = $1
                                             $0 = .shape(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Origin Z",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .shape(module) = $0 { return module.originOffset.z }
                                         return nil
                                     }, set: {
                                         if case var .shape(module) = $0 {
                                             module.originOffset.z = $1
                                             $0 = .shape(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Box X",
                                     moduleFloatBinding(index, fallback: 0.5, get: {
                                         if case let .shape(module) = $0 { return module.boxHalfExtents.x }
                                         return nil
                                     }, set: {
                                         if case var .shape(module) = $0 {
                                             module.boxHalfExtents.x = $1
                                             $0 = .shape(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Box Y",
                                     moduleFloatBinding(index, fallback: 0.5, get: {
                                         if case let .shape(module) = $0 { return module.boxHalfExtents.y }
                                         return nil
                                     }, set: {
                                         if case var .shape(module) = $0 {
                                             module.boxHalfExtents.y = $1
                                             $0 = .shape(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Box Z",
                                     moduleFloatBinding(index, fallback: 0.5, get: {
                                         if case let .shape(module) = $0 { return module.boxHalfExtents.z }
                                         return nil
                                     }, set: {
                                         if case var .shape(module) = $0 {
                                             module.boxHalfExtents.z = $1
                                             $0 = .shape(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Cone R",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .shape(module) = $0 { return module.coneRadius }
                                         return nil
                                     }, set: {
                                         if case var .shape(module) = $0 {
                                             module.coneRadius = $1
                                             $0 = .shape(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Cone H",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .shape(module) = $0 { return module.coneHeight }
                                         return nil
                                     }, set: {
                                         if case var .shape(module) = $0 {
                                             module.coneHeight = $1
                                             $0 = .shape(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                ]))
            case .velocity:
                return AnyView(moduleEditorRows([
                    [
                        moduleNumber("Vel X",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .velocity(module) = $0 { return module.startVelocity.x }
                                         return nil
                                     }, set: {
                                         if case var .velocity(module) = $0 {
                                             module.startVelocity.x = $1
                                             $0 = .velocity(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Vel Y",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .velocity(module) = $0 { return module.startVelocity.y }
                                         return nil
                                     }, set: {
                                         if case var .velocity(module) = $0 {
                                             module.startVelocity.y = $1
                                             $0 = .velocity(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Vel Z",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .velocity(module) = $0 { return module.startVelocity.z }
                                         return nil
                                     }, set: {
                                         if case var .velocity(module) = $0 {
                                             module.startVelocity.z = $1
                                             $0 = .velocity(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Rand X",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .velocity(module) = $0 { return module.velocityRandomness.x }
                                         return nil
                                     }, set: {
                                         if case var .velocity(module) = $0 {
                                             module.velocityRandomness.x = $1
                                             $0 = .velocity(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Rand Y",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .velocity(module) = $0 { return module.velocityRandomness.y }
                                         return nil
                                     }, set: {
                                         if case var .velocity(module) = $0 {
                                             module.velocityRandomness.y = $1
                                             $0 = .velocity(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Rand Z",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .velocity(module) = $0 { return module.velocityRandomness.z }
                                         return nil
                                     }, set: {
                                         if case var .velocity(module) = $0 {
                                             module.velocityRandomness.z = $1
                                             $0 = .velocity(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Inherit",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .velocity(module) = $0 { return module.velocityInheritance }
                                         return nil
                                     }, set: {
                                         if case var .velocity(module) = $0 {
                                             module.velocityInheritance = $1
                                             $0 = .velocity(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 10,
                                     step: 0.05,
                                     enabled: isEnabled),
                    ],
                ]))
            case .forces:
                return AnyView(moduleEditorRows([
                    [
                        moduleEnum("Force",
                                   moduleValueBinding(index, fallback: .none, get: {
                                       if case let .forces(module) = $0 { return module.forceMode }
                                       return nil
                                   }, set: {
                                       if case var .forces(module) = $0 {
                                           module.forceMode = $1
                                           $0 = .forces(module)
                                       }
                                   }),
                                   width: 132,
                                   enabled: isEnabled,
                                   label: particleForceModeLabel),
                        moduleEnum("Vector Field",
                                   moduleValueBinding(index, fallback: .none, get: {
                                       if case let .forces(module) = $0 { return module.vectorFieldMode }
                                       return nil
                                   }, set: {
                                       if case var .forces(module) = $0 {
                                           module.vectorFieldMode = $1
                                           $0 = .forces(module)
                                       }
                                   }),
                                   width: 132,
                                   enabled: isEnabled,
                                   label: particleVectorFieldModeLabel),
                    ],
                    [
                        moduleNumber("Gravity X",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.gravity.x }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.gravity.x = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: -100,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Gravity Y",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.gravity.y }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.gravity.y = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: -100,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Gravity Z",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.gravity.z }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.gravity.z = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: -100,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Noise",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.noiseStrength }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.noiseStrength = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Noise Scale",
                                     moduleFloatBinding(index, fallback: 1, get: {
                                         if case let .forces(module) = $0 { return module.noiseScale }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.noiseScale = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: 0.0001,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Noise Speed",
                                     moduleFloatBinding(index, fallback: 1, get: {
                                         if case let .forces(module) = $0 { return module.noiseSpeed }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.noiseSpeed = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Force",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.forceStrength }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.forceStrength = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Radius",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.forceRadius }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.forceRadius = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Falloff",
                                     moduleFloatBinding(index, fallback: 1, get: {
                                         if case let .forces(module) = $0 { return module.forceFalloff }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.forceFalloff = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 32,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Center X",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.forceCenter.x }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.forceCenter.x = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Center Y",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.forceCenter.y }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.forceCenter.y = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Center Z",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.forceCenter.z }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.forceCenter.z = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("VF Strength",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.vectorFieldStrength }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.vectorFieldStrength = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("VF Scale",
                                     moduleFloatBinding(index, fallback: 1, get: {
                                         if case let .forces(module) = $0 { return module.vectorFieldScale }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.vectorFieldScale = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: 0.0001,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("VF Scroll",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .forces(module) = $0 { return module.vectorFieldScrollSpeed }
                                         return nil
                                     }, set: {
                                         if case var .forces(module) = $0 {
                                             module.vectorFieldScrollSpeed = $1
                                             $0 = .forces(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                ]))
            case .collision:
                return AnyView(moduleEditorRows([
                    [
                        moduleEnum("Mode",
                                   moduleValueBinding(index, fallback: .none, get: {
                                       if case let .collision(module) = $0 { return module.collisionMode }
                                       return nil
                                   }, set: {
                                       if case var .collision(module) = $0 {
                                           module.collisionMode = $1
                                           $0 = .collision(module)
                                       }
                                   }),
                                   width: 132,
                                   enabled: isEnabled,
                                   label: particleCollisionModeLabel),
                        moduleNumber("Plane Y",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .collision(module) = $0 { return module.collisionPlaneY }
                                         return nil
                                     }, set: {
                                         if case var .collision(module) = $0 {
                                             module.collisionPlaneY = $1
                                             $0 = .collision(module)
                                         }
                                     }),
                                     min: -1000,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Bounce",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .collision(module) = $0 { return module.collisionRestitution }
                                         return nil
                                     }, set: {
                                         if case var .collision(module) = $0 {
                                             module.collisionRestitution = $1
                                             $0 = .collision(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1,
                                     step: 0.05,
                                     enabled: isEnabled),
                        moduleNumber("Damping",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .collision(module) = $0 { return module.collisionDamping }
                                         return nil
                                     }, set: {
                                         if case var .collision(module) = $0 {
                                             module.collisionDamping = $1
                                             $0 = .collision(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1,
                                     step: 0.05,
                                     enabled: isEnabled),
                    ],
                ]))
            case .appearance:
                return AnyView(moduleEditorRows([
                    [
                        moduleEnum("Blend",
                                   moduleValueBinding(index, fallback: .alpha, get: {
                                       if case let .appearance(module) = $0 { return module.blendMode }
                                       return nil
                                   }, set: {
                                       if case var .appearance(module) = $0 {
                                           module.blendMode = $1
                                           $0 = .appearance(module)
                                       }
                                   }),
                                   width: 132,
                                   enabled: isEnabled,
                                   label: particleBlendModeLabel),
                        moduleNumber("Life",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .appearance(module) = $0 { return module.lifetime }
                                         return nil
                                     }, set: {
                                         if case var .appearance(module) = $0 {
                                             module.lifetime = $1
                                             $0 = .appearance(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 60,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Start",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .appearance(module) = $0 { return module.startSize }
                                         return nil
                                     }, set: {
                                         if case var .appearance(module) = $0 {
                                             module.startSize = $1
                                             $0 = .appearance(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("End",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .appearance(module) = $0 { return module.endSize }
                                         return nil
                                     }, set: {
                                         if case var .appearance(module) = $0 {
                                             module.endSize = $1
                                             $0 = .appearance(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Life Rand",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .appearance(module) = $0 { return module.lifetimeRandomness }
                                         return nil
                                     }, set: {
                                         if case var .appearance(module) = $0 {
                                             module.lifetimeRandomness = $1
                                             $0 = .appearance(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 60,
                                     step: 0.05,
                                     enabled: isEnabled),
                        moduleNumber("Size Rand",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .appearance(module) = $0 { return module.sizeRandomness }
                                         return nil
                                     }, set: {
                                         if case var .appearance(module) = $0 {
                                             module.sizeRandomness = $1
                                             $0 = .appearance(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.05,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Rotation",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .appearance(module) = $0 { return module.startRotation }
                                         return nil
                                     }, set: {
                                         if case var .appearance(module) = $0 {
                                             module.startRotation = $1
                                             $0 = .appearance(module)
                                         }
                                     }),
                                     min: -360,
                                     max: 360,
                                     step: 1,
                                     enabled: isEnabled),
                        moduleNumber("Rot Rand",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .appearance(module) = $0 { return module.rotationRandomness }
                                         return nil
                                     }, set: {
                                         if case var .appearance(module) = $0 {
                                             module.rotationRandomness = $1
                                             $0 = .appearance(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 360,
                                     step: 1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Spin",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .appearance(module) = $0 { return module.angularVelocity }
                                         return nil
                                     }, set: {
                                         if case var .appearance(module) = $0 {
                                             module.angularVelocity = $1
                                             $0 = .appearance(module)
                                         }
                                     }),
                                     min: -3600,
                                     max: 3600,
                                     step: 1,
                                     enabled: isEnabled),
                        moduleNumber("Spin Rand",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .appearance(module) = $0 { return module.angularVelocityRandomness }
                                         return nil
                                     }, set: {
                                         if case var .appearance(module) = $0 {
                                             module.angularVelocityRandomness = $1
                                             $0 = .appearance(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 3600,
                                     step: 1,
                                     enabled: isEnabled),
                    ],
                ]))
            case .textureSheet:
                return AnyView(moduleEditorRows([
                    [
                        moduleEnum("Playback",
                                   moduleValueBinding(index, fallback: .automatic, get: {
                                       if case let .textureSheet(module) = $0 { return module.playbackMode }
                                       return nil
                                   }, set: {
                                       if case var .textureSheet(module) = $0 {
                                           module.playbackMode = $1
                                           $0 = .textureSheet(module)
                                       }
                                   }),
                                   width: 140,
                                   enabled: isEnabled,
                                   label: particleTextureSheetPlaybackModeLabel),
                        moduleNumber("Frame Rate",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .textureSheet(module) = $0 { return module.frameRate }
                                         return nil
                                     }, set: {
                                         if case var .textureSheet(module) = $0 {
                                             module.frameRate = $1
                                             $0 = .textureSheet(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 240,
                                     step: 1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Cols",
                                     moduleIntBinding(index, fallback: 1, get: {
                                         if case let .textureSheet(module) = $0 { return module.columns }
                                         return nil
                                     }, set: {
                                         if case var .textureSheet(module) = $0 {
                                             module.columns = $1
                                             $0 = .textureSheet(module)
                                         }
                                     }),
                                     min: 1,
                                     max: 64,
                                     step: 1,
                                     enabled: isEnabled),
                        moduleNumber("Rows",
                                     moduleIntBinding(index, fallback: 1, get: {
                                         if case let .textureSheet(module) = $0 { return module.rows }
                                         return nil
                                     }, set: {
                                         if case var .textureSheet(module) = $0 {
                                             module.rows = $1
                                             $0 = .textureSheet(module)
                                         }
                                     }),
                                     min: 1,
                                     max: 64,
                                     step: 1,
                                     enabled: isEnabled),
                        moduleNumber("Frames",
                                     moduleIntBinding(index, fallback: 1, get: {
                                         if case let .textureSheet(module) = $0 { return module.frameCount }
                                         return nil
                                     }, set: {
                                         if case var .textureSheet(module) = $0 {
                                             module.frameCount = $1
                                             $0 = .textureSheet(module)
                                         }
                                     }),
                                     min: 1,
                                     max: 4096,
                                     step: 1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Start Frame",
                                     moduleIntBinding(index, fallback: 0, get: {
                                         if case let .textureSheet(module) = $0 { return module.startFrame }
                                         return nil
                                     }, set: {
                                         if case var .textureSheet(module) = $0 {
                                             module.startFrame = $1
                                             $0 = .textureSheet(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 4096,
                                     step: 1,
                                     enabled: isEnabled),
                        moduleNumber("Frame Rand",
                                     moduleIntBinding(index, fallback: 0, get: {
                                         if case let .textureSheet(module) = $0 { return module.frameRandomness }
                                         return nil
                                     }, set: {
                                         if case var .textureSheet(module) = $0 {
                                             module.frameRandomness = $1
                                             $0 = .textureSheet(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 4096,
                                     step: 1,
                                     enabled: isEnabled),
                    ],
                ]))
            case .renderer:
                return AnyView(moduleEditorRows([
                    [
                        moduleEnum("Mode",
                                   moduleValueBinding(index, fallback: .billboard, get: {
                                       if case let .renderer(module) = $0 { return module.renderMode }
                                       return nil
                                   }, set: {
                                       if case var .renderer(module) = $0 {
                                           module.renderMode = $1
                                           $0 = .renderer(module)
                                       }
                                   }),
                                   width: 132,
                                   enabled: isEnabled,
                                   label: particleRenderModeLabel),
                        moduleEnum("Sort",
                                   moduleValueBinding(index, fallback: .distanceDescending, get: {
                                       if case let .renderer(module) = $0 { return module.sortMode }
                                       return nil
                                   }, set: {
                                       if case var .renderer(module) = $0 {
                                           module.sortMode = $1
                                           $0 = .renderer(module)
                                       }
                                   }),
                                   width: 150,
                                   enabled: isEnabled,
                                   label: particleSortModeLabel),
                    ],
                    [
                        moduleEnum("Align",
                                   moduleValueBinding(index, fallback: .billboard, get: {
                                       if case let .renderer(module) = $0 { return module.renderAlignment }
                                       return nil
                                   }, set: {
                                       if case var .renderer(module) = $0 {
                                           module.renderAlignment = $1
                                           $0 = .renderer(module)
                                       }
                                   }),
                                   width: 132,
                                   enabled: isEnabled,
                                   label: particleRenderAlignmentLabel),
                        moduleEnum("Bounds",
                                   moduleValueBinding(index, fallback: .automatic, get: {
                                       if case let .renderer(module) = $0 { return module.renderBoundsMode }
                                       return nil
                                   }, set: {
                                       if case var .renderer(module) = $0 {
                                           module.renderBoundsMode = $1
                                           $0 = .renderer(module)
                                       }
                                   }),
                                   width: 132,
                                   enabled: isEnabled,
                                   label: particleRenderBoundsModeLabel),
                    ],
                    [
                        moduleNumber("Max Dist",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .renderer(module) = $0 { return module.maxRenderDistance }
                                         return nil
                                     }, set: {
                                         if case var .renderer(module) = $0 {
                                             module.maxRenderDistance = $1
                                             $0 = .renderer(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100_000,
                                     step: 1,
                                     enabled: isEnabled),
                        moduleNumber("Fade",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .renderer(module) = $0 { return module.renderDistanceFadeRange }
                                         return nil
                                     }, set: {
                                         if case var .renderer(module) = $0 {
                                             module.renderDistanceFadeRange = $1
                                             $0 = .renderer(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100_000,
                                     step: 1,
                                     enabled: isEnabled),
                        moduleNumber("LOD Min",
                                     moduleFloatBinding(index, fallback: 1, get: {
                                         if case let .renderer(module) = $0 { return module.renderLODMinParticleScale }
                                         return nil
                                     }, set: {
                                         if case var .renderer(module) = $0 {
                                             module.renderLODMinParticleScale = $1
                                             $0 = .renderer(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1,
                                     step: 0.05,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("LOD Start",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .renderer(module) = $0 { return module.renderLODStartDistance }
                                         return nil
                                     }, set: {
                                         if case var .renderer(module) = $0 {
                                             module.renderLODStartDistance = $1
                                             $0 = .renderer(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100_000,
                                     step: 1,
                                     enabled: isEnabled),
                        moduleNumber("LOD End",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .renderer(module) = $0 { return module.renderLODEndDistance }
                                         return nil
                                     }, set: {
                                         if case var .renderer(module) = $0 {
                                             module.renderLODEndDistance = $1
                                             $0 = .renderer(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100_000,
                                     step: 1,
                                     enabled: isEnabled),
                        moduleNumber("Bounds R",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .renderer(module) = $0 { return module.renderBoundsRadius }
                                         return nil
                                     }, set: {
                                         if case var .renderer(module) = $0 {
                                             module.renderBoundsRadius = $1
                                             $0 = .renderer(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100_000,
                                     step: 1,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Stretch",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .renderer(module) = $0 { return module.velocityStretchScale }
                                         return nil
                                     }, set: {
                                         if case var .renderer(module) = $0 {
                                             module.velocityStretchScale = $1
                                             $0 = .renderer(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.05,
                                     enabled: isEnabled),
                        moduleNumber("Stretch Max",
                                     moduleFloatBinding(index, fallback: 8, get: {
                                         if case let .renderer(module) = $0 { return module.velocityStretchMax }
                                         return nil
                                     }, set: {
                                         if case var .renderer(module) = $0 {
                                             module.velocityStretchMax = $1
                                             $0 = .renderer(module)
                                         }
                                     }),
                                     min: 1,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                    ],
                ]))
            case .trails:
                return AnyView(moduleEditorRows([
                    [
                        moduleNumber("Length",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .trails(module) = $0 { return module.trailLength }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.trailLength = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 60,
                                     step: 0.05,
                                     enabled: isEnabled),
                        moduleNumber("Segments",
                                     moduleIntBinding(index, fallback: 0, get: {
                                         if case let .trails(module) = $0 { return module.trailSegments }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.trailSegments = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 128,
                                     step: 1,
                                     enabled: isEnabled),
                        moduleNumber("End Alpha",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .trails(module) = $0 { return module.trailEndAlphaScale }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.trailEndAlphaScale = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1,
                                     step: 0.05,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Width",
                                     moduleFloatBinding(index, fallback: 1, get: {
                                         if case let .trails(module) = $0 { return module.ribbonWidthScale }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.ribbonWidthScale = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.05,
                                     enabled: isEnabled),
                        moduleNumber("Tail Width",
                                     moduleFloatBinding(index, fallback: 1, get: {
                                         if case let .trails(module) = $0 { return module.ribbonTailWidthScale }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.ribbonTailWidthScale = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.05,
                                     enabled: isEnabled),
                        moduleNumber("Tiling",
                                     moduleFloatBinding(index, fallback: 1, get: {
                                         if case let .trails(module) = $0 { return module.ribbonTextureTiling }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.ribbonTextureTiling = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.05,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("End Size",
                                     moduleFloatBinding(index, fallback: 0.5, get: {
                                         if case let .trails(module) = $0 { return module.trailEndSizeScale }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.trailEndSizeScale = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 100,
                                     step: 0.05,
                                     enabled: isEnabled),
                        moduleNumber("Tail Alpha",
                                     moduleFloatBinding(index, fallback: 1, get: {
                                         if case let .trails(module) = $0 { return module.ribbonTailAlphaScale }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.ribbonTailAlphaScale = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1,
                                     step: 0.05,
                                     enabled: isEnabled),
                        moduleNumber("Offset",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .trails(module) = $0 { return module.ribbonTextureOffset }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.ribbonTextureOffset = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: -100,
                                     max: 100,
                                     step: 0.05,
                                     enabled: isEnabled),
                    ],
                    [
                        moduleNumber("Max Segment",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .trails(module) = $0 { return module.ribbonMaxSegmentLength }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.ribbonMaxSegmentLength = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 1000,
                                     step: 0.1,
                                     enabled: isEnabled),
                        moduleNumber("Join",
                                     moduleFloatBinding(index, fallback: 0, get: {
                                         if case let .trails(module) = $0 { return module.ribbonJoinOverlapScale }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.ribbonJoinOverlapScale = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 0,
                                     max: 10,
                                     step: 0.05,
                                     enabled: isEnabled),
                        moduleNumber("Smooth",
                                     moduleIntBinding(index, fallback: 1, get: {
                                         if case let .trails(module) = $0 { return module.ribbonSmoothingSegments }
                                         return nil
                                     }, set: {
                                         if case var .trails(module) = $0 {
                                             module.ribbonSmoothingSegments = $1
                                             $0 = .trails(module)
                                         }
                                     }),
                                     min: 1,
                                     max: 16,
                                     step: 1,
                                     enabled: isEnabled),
                    ],
                ]))
            case .subEmitters:
                return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 5) {
                    moduleEditorRows([
                        [
                            moduleEnum("Trigger",
                                       moduleValueBinding(index, fallback: .none, get: {
                                           if case let .subEmitters(module) = $0 { return module.legacyTrigger }
                                           return nil
                                       }, set: {
                                           if case var .subEmitters(module) = $0 {
                                               module.legacyTrigger = $1
                                               $0 = .subEmitters(module)
                                           }
                                       }),
                                       width: 132,
                                       enabled: isEnabled,
                                       label: particleSubEmitterTriggerLabel),
                            moduleNumber("Burst",
                                         moduleIntBinding(index, fallback: 0, get: {
                                             if case let .subEmitters(module) = $0 { return module.legacyBurstCount }
                                             return nil
                                         }, set: {
                                             if case var .subEmitters(module) = $0 {
                                                 module.legacyBurstCount = $1
                                                 $0 = .subEmitters(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 100_000,
                                         step: 1,
                                         enabled: isEnabled),
                            moduleNumber("Probability",
                                         moduleFloatBinding(index, fallback: 1, get: {
                                             if case let .subEmitters(module) = $0 { return module.legacyProbability }
                                             return nil
                                         }, set: {
                                             if case var .subEmitters(module) = $0 {
                                                 module.legacyProbability = $1
                                                 $0 = .subEmitters(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 1,
                                         step: 0.05,
                                         enabled: isEnabled),
                        ],
                        [
                            moduleNumber("Max Depth",
                                         moduleIntBinding(index, fallback: 0, get: {
                                             if case let .subEmitters(module) = $0 { return module.legacyMaxDepth }
                                             return nil
                                         }, set: {
                                             if case var .subEmitters(module) = $0 {
                                                 module.legacyMaxDepth = $1
                                                 $0 = .subEmitters(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 16,
                                         step: 1,
                                         enabled: isEnabled),
                            moduleNumber("Inherit",
                                         moduleFloatBinding(index, fallback: 0, get: {
                                             if case let .subEmitters(module) = $0 { return module.legacyInheritVelocity }
                                             return nil
                                         }, set: {
                                             if case var .subEmitters(module) = $0 {
                                                 module.legacyInheritVelocity = $1
                                                 $0 = .subEmitters(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 10,
                                         step: 0.05,
                                         enabled: isEnabled),
                            moduleNumber("Life",
                                         moduleFloatBinding(index, fallback: 1, get: {
                                             if case let .subEmitters(module) = $0 { return module.legacyLifetime }
                                             return nil
                                         }, set: {
                                             if case var .subEmitters(module) = $0 {
                                                 module.legacyLifetime = $1
                                                 $0 = .subEmitters(module)
                                             }
                                         }),
                                         min: 0.0001,
                                         max: 60,
                                         step: 0.1,
                                         enabled: isEnabled),
                        ],
                    ])

                    Box(direction: .column, alignItems: .stretch, spacing: 4) {
                        Row(alignment: .center, spacing: 0) {
                            Spacer(minLength: 0)
                                .frame(width: 28)
                            Text(L("Rules"))
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                                .flex()
                        }
                        InspectorParticleSubEmittersValue(binding: moduleSubEmitterRulesBinding(index))
                            .opacity(isEnabled ? 1 : 0.66)
                    }
                })
            case .gpuSimulation:
                return AnyView(moduleEditorRows([
                    [
                        moduleEnum("Space",
                                   moduleValueBinding(index, fallback: .local, get: {
                                       if case let .gpuSimulation(module) = $0 { return module.simulationSpace }
                                       return nil
                                   }, set: {
                                       if case var .gpuSimulation(module) = $0 {
                                           module.simulationSpace = $1
                                           $0 = .gpuSimulation(module)
                                       }
                                   }),
                                   width: 132,
                                   enabled: isEnabled,
                                   label: particleSimulationSpaceLabel),
                        moduleEnum("Backend",
                                   moduleValueBinding(index, fallback: .cpu, get: {
                                       if case let .gpuSimulation(module) = $0 { return module.simulationBackend }
                                       return nil
                                   }, set: {
                                       if case var .gpuSimulation(module) = $0 {
                                           module.simulationBackend = $1
                                           $0 = .gpuSimulation(module)
                                       }
                                   }),
                                   width: 150,
                                   enabled: isEnabled,
                                   label: particleSimulationBackendLabel),
                    ],
                    [
                        moduleNumber("Group",
                                     moduleIntBinding(index, fallback: 64, get: {
                                         if case let .gpuSimulation(module) = $0 { return module.workgroupSize }
                                         return nil
                                     }, set: {
                                         if case var .gpuSimulation(module) = $0 {
                                             module.workgroupSize = $1
                                             $0 = .gpuSimulation(module)
                                         }
                                     }),
                                     min: 1,
                                     max: Float(ParticleGPUSimulationPlan.maximumWorkgroupSize),
                                     step: 1,
                                     enabled: isEnabled),
                    ],
                ]))
            }
        }

        private func moduleEditorRows(_ rows: [[AnyView]]) -> AnyView {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 5) {
                for fields in rows {
                    moduleEditorRow(fields)
                }
            })
        }

        private func moduleEditorRow(_ fields: [AnyView]) -> AnyView {
            AnyView(Row(alignment: .center, spacing: 8) {
                Spacer(minLength: 0)
                    .frame(width: 28)
                for field in fields {
                    field
                }
            })
        }

        private func moduleNumber(_ label: String,
                                  _ value: Binding<Float>,
                                  min: Float?,
                                  max: Float?,
                                  step: Float?,
                                  enabled: Bool) -> AnyView {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 2) {
                Text(L(label))
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                NumberField(value: value,
                            decimals: 2,
                            size: .small,
                            isEnabled: enabled,
                            minValue: min,
                            maxValue: max,
                            step: step,
                            showsStepper: true)
                    .frame(minWidth: 70)
            }
            .flex())
        }

        private func moduleEnum<Value: Hashable & CaseIterable>(_ label: String,
                                                                _ value: Binding<Value>,
                                                                width: Float,
                                                                enabled: Bool,
                                                                label optionLabel: @escaping (Value) -> String) -> AnyView
            where Value.AllCases: Collection {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 2) {
                Text(L(label))
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                EnumField(value: value,
                          isEnabled: enabled,
                          width: width,
                          label: optionLabel)
                    .frame(minWidth: min(width, 120))
            }
            .flex())
        }

        private func moduleFloatBinding(_ index: Int,
                                        fallback: Float,
                                        get: @escaping (ParticleEmitterModuleSettings) -> Float?,
                                        set: @escaping (inout ParticleEmitterModuleSettings, Float) -> Void)
            -> Binding<Float> {
            Binding(
                get: {
                    guard binding.wrappedValue.modules.indices.contains(index) else { return fallback }
                    return get(binding.wrappedValue.modules[index].settings) ?? fallback
                },
                set: { next in
                    var stack = binding.wrappedValue
                    guard stack.modules.indices.contains(index) else { return }
                    set(&stack.modules[index].settings, next)
                    binding.wrappedValue = stack
                }
            )
        }

        private func moduleIntBinding(_ index: Int,
                                      fallback: Int,
                                      get: @escaping (ParticleEmitterModuleSettings) -> Int?,
                                      set: @escaping (inout ParticleEmitterModuleSettings, Int) -> Void)
            -> Binding<Float> {
            Binding(
                get: {
                    guard binding.wrappedValue.modules.indices.contains(index) else { return Float(fallback) }
                    return Float(get(binding.wrappedValue.modules[index].settings) ?? fallback)
                },
                set: { next in
                    var stack = binding.wrappedValue
                    guard stack.modules.indices.contains(index) else { return }
                    set(&stack.modules[index].settings, max(0, Int(next.rounded())))
                    binding.wrappedValue = stack
                }
            )
        }

        private func moduleValueBinding<Value>(_ index: Int,
                                               fallback: Value,
                                               get: @escaping (ParticleEmitterModuleSettings) -> Value?,
                                               set: @escaping (inout ParticleEmitterModuleSettings, Value) -> Void)
            -> Binding<Value> {
            Binding(
                get: {
                    guard binding.wrappedValue.modules.indices.contains(index) else { return fallback }
                    return get(binding.wrappedValue.modules[index].settings) ?? fallback
                },
                set: { next in
                    var stack = binding.wrappedValue
                    guard stack.modules.indices.contains(index) else { return }
                    set(&stack.modules[index].settings, next)
                    binding.wrappedValue = stack
                }
            )
        }

        private func moduleSubEmitterRulesBinding(_ index: Int) -> Binding<[ParticleSubEmitter]> {
            Binding(
                get: {
                    guard binding.wrappedValue.modules.indices.contains(index),
                          case let .subEmitters(module) = binding.wrappedValue.modules[index].settings else {
                        return []
                    }
                    return module.rules
                },
                set: { next in
                    var stack = binding.wrappedValue
                    guard stack.modules.indices.contains(index),
                          case var .subEmitters(module) = stack.modules[index].settings else {
                        return
                    }
                    module.rules = next
                    stack.modules[index].settings = .subEmitters(module)
                    binding.wrappedValue = stack
                }
            )
        }

        private func particleEmissionShapeLabel(_ shape: ParticleEmissionShape) -> String {
            switch shape {
            case .sphere: return L("Sphere")
            case .box: return L("Box")
            case .cone: return L("Cone")
            }
        }

        private func particleCollisionModeLabel(_ mode: ParticleCollisionMode) -> String {
            switch mode {
            case .none: return L("None")
            case .localPlane: return L("Local Plane")
            case .worldPlane: return L("World Plane")
            }
        }

        private func particleSimulationSpaceLabel(_ space: ParticleSimulationSpace) -> String {
            switch space {
            case .local: return L("Local")
            case .world: return L("World")
            }
        }

        private func particleSimulationBackendLabel(_ backend: ParticleSimulationBackend) -> String {
            switch backend {
            case .cpu: return L("CPU")
            case .gpuIfSupported: return L("GPU Preferred")
            case .gpuRequired: return L("GPU Required")
            }
        }

        private func particleBlendModeLabel(_ mode: ParticleBlendMode) -> String {
            switch mode {
            case .alpha: return L("Alpha")
            case .additive: return L("Additive")
            }
        }

        private func particleRenderAlignmentLabel(_ alignment: ParticleRenderAlignment) -> String {
            switch alignment {
            case .billboard: return L("Billboard")
            case .velocity: return L("Velocity")
            }
        }

        private func particleRenderModeLabel(_ mode: ParticleRenderMode) -> String {
            switch mode {
            case .billboard: return L("Billboard")
            case .ribbon: return L("Ribbon")
            }
        }

        private func particleSortModeLabel(_ mode: ParticleSortMode) -> String {
            switch mode {
            case .distanceDescending: return L("Back to Front")
            case .distanceAscending: return L("Front to Back")
            case .oldestFirst: return L("Oldest First")
            case .youngestFirst: return L("Youngest First")
            }
        }

        private func particleTextureSheetPlaybackModeLabel(_ mode: ParticleTextureSheetPlaybackMode) -> String {
            switch mode {
            case .automatic: return L("Auto")
            case .lifetime: return L("Lifetime")
            case .playOnce: return L("Play Once")
            case .loop: return L("Loop")
            case .singleFrame: return L("Single Frame")
            }
        }

        private func particleRenderBoundsModeLabel(_ mode: ParticleRenderBoundsMode) -> String {
            switch mode {
            case .disabled: return L("Disabled")
            case .manual: return L("Manual")
            case .automatic: return L("Automatic")
            }
        }

        private func particleForceModeLabel(_ mode: ParticleForceMode) -> String {
            switch mode {
            case .none: return L("None")
            case .radial: return L("Radial")
            case .vortex: return L("Vortex")
            }
        }

        private func particleVectorFieldModeLabel(_ mode: ParticleVectorFieldMode) -> String {
            switch mode {
            case .none: return L("None")
            case .uniform: return L("Uniform")
            case .curl: return L("Curl")
            }
        }

        private func particleSubEmitterTriggerLabel(_ trigger: ParticleSubEmitterTrigger) -> String {
            switch trigger {
            case .none: return L("None")
            case .death: return L("Death")
            case .collision: return L("Collision")
            }
        }

        private func moduleDetail(_ settings: ParticleEmitterModuleSettings) -> String {
            switch settings {
            case let .emission(module):
                return "\(fmt(module.emissionRate))/s · max \(module.maxParticles)"
            case let .shape(module):
                return "\(module.emissionShape.rawValue) · r \(fmt(module.spawnRadius))"
            case let .velocity(module):
                return "v \(vec(module.startVelocity)) · inherit \(fmt(module.velocityInheritance))"
            case let .forces(module):
                return "\(module.forceMode.rawValue) · noise \(fmt(module.noiseStrength))"
            case let .collision(module):
                return "\(module.collisionMode.rawValue) · bounce \(fmt(module.collisionRestitution))"
            case let .appearance(module):
                return "life \(fmt(module.lifetime)) · size \(fmt(module.startSize)) -> \(fmt(module.endSize))"
            case let .textureSheet(module):
                return "\(module.columns)x\(module.rows) · \(module.playbackMode.rawValue)"
            case let .renderer(module):
                return "\(module.renderMode.rawValue) · \(module.sortMode.rawValue)"
            case let .trails(module):
                return "trail \(fmt(module.trailLength))s · \(module.trailSegments) samples"
            case let .subEmitters(module):
                return "\(module.rules.count) rules · legacy \(module.legacyTrigger.rawValue)"
            case let .gpuSimulation(module):
                return "\(module.simulationBackend.rawValue) · \(module.workgroupSize) threads"
            }
        }

        private func fmt(_ value: Float) -> String {
            let rounded = (value * 100).rounded() / 100
            if rounded == Float(Int(rounded)) {
                return "\(Int(rounded))"
            }
            return "\(rounded)"
        }

        private func formatMs(_ seconds: Float) -> String {
            let ms = max(0, seconds) * 1000
            return "\(fmt(ms))ms"
        }

        private func vec(_ value: SIMD3<Float>) -> String {
            "(\(fmt(value.x)), \(fmt(value.y)), \(fmt(value.z)))"
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
        let showsStepper: Bool

        var body: some View {
            NumberField(value: binding,
                        decimals: 2,
                        size: .small,
                        minValue: minValue,
                        maxValue: maxValue,
                        step: step,
                        showsStepper: showsStepper)
                .frame(minWidth: 96)
                .flex()
        }
    }

    private struct InspectorTextValue: View {
        let identity: String
        let binding: Binding<String>

        var body: some View {
            // Draft-while-editing: model normalization (empty entity name →
            // fallback, clip lookups) must not rewrite the text mid-edit.
            CommitOnBlurTextField(identity: identity, text: binding, size: .small)
                .flex()
                .clipped()
        }
    }

    private struct InspectorVectorValue: View {
        let x: Binding<Float>
        let y: Binding<Float>
        let z: Binding<Float>

        var body: some View {
            Vec3Field(x: x, y: y, z: z, decimals: 2, size: .small)
                .flex(1, shrink: 1, basis: 0)
                .clipped()
        }
    }

    private struct InspectorColorValue: View {
        let binding: Binding<Color>

        var body: some View {
            ColorField(color: binding,
                       showAlpha: false,
                       showsInlineValues: true)
                .flex()
                .clipped()
        }
    }

    private struct InspectorLightTypeValue: View {
        let binding: Binding<LightType>

        var body: some View {
            EnumField(value: binding, width: 150) { type in
                switch type {
                case .directional: return L("Directional")
                case .point: return L("Point")
                case .spot: return L("Spot")
                }
            }
        }
    }

    private struct InspectorRigidBodyMotionValue: View {
        let binding: Binding<RigidBodyMotionType>

        var body: some View {
            EnumField(value: binding, width: 150) { type in
                switch type {
                case .static: return L("Static")
                case .dynamic: return L("Dynamic")
                case .kinematic: return L("Kinematic")
                }
            }
        }
    }

    private struct InspectorColliderShapeKindValue: View {
        let binding: Binding<ColliderShapeKind>

        var body: some View {
            EnumField(value: binding, width: 150) { kind in
                switch kind {
                case .box: return L("Box")
                case .sphere: return L("Sphere")
                case .capsule: return L("Capsule")
                case .mesh: return L("Mesh")
                case .convex: return L("Convex")
                }
            }
        }
    }

    private struct InspectorParticleEmissionShapeValue: View {
        let binding: Binding<ParticleEmissionShape>

        var body: some View {
            EnumField(value: binding, width: 150) { shape in
                switch shape {
                case .sphere: return L("Sphere")
                case .box: return L("Box")
                case .cone: return L("Cone")
                }
            }
        }
    }

    private struct InspectorParticleCollisionModeValue: View {
        let binding: Binding<ParticleCollisionMode>

        var body: some View {
            EnumField(value: binding, width: 150) { mode in
                switch mode {
                case .none: return L("None")
                case .localPlane: return L("Local Plane")
                case .worldPlane: return L("World Plane")
                }
            }
        }
    }

    private struct InspectorParticleSimulationSpaceValue: View {
        let binding: Binding<ParticleSimulationSpace>

        var body: some View {
            EnumField(value: binding, width: 150) { space in
                switch space {
                case .local: return L("Local")
                case .world: return L("World")
                }
            }
        }
    }

    private struct InspectorParticleSimulationBackendValue: View {
        let binding: Binding<ParticleSimulationBackend>

        var body: some View {
            EnumField(value: binding, width: 170) { backend in
                switch backend {
                case .cpu: return L("CPU")
                case .gpuIfSupported: return L("GPU Preferred")
                case .gpuRequired: return L("GPU Required")
                }
            }
        }
    }

    private struct InspectorParticleCurveValue: View {
        let binding: Binding<ParticleCurve>
        @State private var selectedKeyIndex: Int? = nil

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 7) {
                toolbar
                if case .keyframes(let keyframes) = binding.wrappedValue {
                    ParticleCurvePreview(binding: binding, selectedKeyIndex: $selectedKeyIndex)
                        .frame(height: ParticleCurveEditorLayout.previewHeight)
                    ParticleCurveKeyframeRows(binding: binding,
                                              keyframes: keyframes,
                                              selectedKeyIndex: $selectedKeyIndex)
                }
            }
            .padding(horizontal: 8, vertical: 8)
            .background(.surfaceSunken)
            .cornerRadius(6)
            .border(.border, width: 1)
            .frame(height: fixedHeight)
            .clipped()
        }

        private var fixedHeight: Float {
            if case .keyframes(let keyframes) = binding.wrappedValue {
                return ParticleCurveEditorLayout.valueHeight(keyframeCount: keyframes.count)
            }
            return ParticleCurveEditorLayout.linearValueHeight
        }

        private var toolbar: some View {
            Row(alignment: .center, spacing: 8) {
                Select(selection: binding,
                       options: options,
                       width: 170)
                if case .keyframes(let keyframes) = binding.wrappedValue {
                    Button(L("Add")) { appendKeyframe(to: keyframes) }
                        .buttonStyle(.secondary)
                        .frame(width: 52, height: 24)
                    Button(L("Reset")) {
                        binding.wrappedValue = .keyframes(Self.defaultKeyframes)
                        selectedKeyIndex = nil
                    }
                        .buttonStyle(.ghost)
                        .frame(width: 58, height: 24)
                }
                Spacer(minLength: 0)
            }
            .frame(height: ParticleCurveEditorLayout.toolbarHeight)
        }

        private var options: [SelectOption<ParticleCurve>] {
            var values: [SelectOption<ParticleCurve>] = [
                SelectOption(value: .constant(1), label: L("Constant")),
                SelectOption(value: .linear, label: L("Linear")),
                SelectOption(value: .easeIn, label: L("Ease In")),
                SelectOption(value: .easeOut, label: L("Ease Out")),
                SelectOption(value: .easeInOut, label: L("Ease In-Out")),
            ]
            if case .constant(let value) = binding.wrappedValue, value != 1 {
                values.append(SelectOption(value: binding.wrappedValue,
                                           label: "\(L("Constant")) \(value)"))
            }
            if case .keyframes(let keyframes) = binding.wrappedValue {
                values.append(SelectOption(value: binding.wrappedValue,
                                           label: "\(L("Keyframes")) (\(keyframes.count))"))
            } else {
                values.append(SelectOption(value: .keyframes(Self.defaultKeyframes),
                                           label: L("Keyframes")))
            }
            return values
        }

        private static let defaultKeyframes: [ParticleCurveKeyframe] = [
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 1, value: 1),
        ]

        private func appendKeyframe(to keyframes: [ParticleCurveKeyframe]) {
            let sorted = keyframes.sortedByTimeStable()
            let insert: ParticleCurveKeyframe
            if sorted.count >= 2 {
                let widestPair = zip(sorted.indices.dropLast(), sorted.indices.dropFirst())
                    .max { lhs, rhs in
                        let leftSpan = sorted[lhs.1].time - sorted[lhs.0].time
                        let rightSpan = sorted[rhs.1].time - sorted[rhs.0].time
                        return leftSpan < rightSpan
                    }
                if let pair = widestPair {
                    let lower = sorted[pair.0]
                    let upper = sorted[pair.1]
                    let time = (lower.time + upper.time) * 0.5
                    let value = (lower.value + upper.value) * 0.5
                    insert = ParticleCurveKeyframe(time: time, value: value)
                } else {
                    insert = ParticleCurveKeyframe(time: 0.5, value: 0.5)
                }
            } else {
                insert = ParticleCurveKeyframe(time: 0.5, value: 0.5)
            }
            let next = (sorted + [insert]).sortedByTimeStable()
            binding.wrappedValue = .keyframes(next)
            selectedKeyIndex = next.nearestIndex(to: insert)
        }

    }

    private struct InspectorParticleBlendModeValue: View {
        let binding: Binding<ParticleBlendMode>

        var body: some View {
            EnumField(value: binding, width: 150) { mode in
                switch mode {
                case .alpha: return L("Alpha")
                case .additive: return L("Additive")
                }
            }
        }
    }

    private struct InspectorParticleRenderAlignmentValue: View {
        let binding: Binding<ParticleRenderAlignment>

        var body: some View {
            EnumField(value: binding, width: 150) { alignment in
                switch alignment {
                case .billboard: return L("Billboard")
                case .velocity: return L("Velocity")
                }
            }
        }
    }

    private struct InspectorParticleRenderModeValue: View {
        let binding: Binding<ParticleRenderMode>

        var body: some View {
            EnumField(value: binding, width: 150) { mode in
                switch mode {
                case .billboard: return L("Billboard")
                case .ribbon: return L("Ribbon")
                }
            }
        }
    }

    private struct InspectorParticleSortModeValue: View {
        let binding: Binding<ParticleSortMode>

        var body: some View {
            EnumField(value: binding, width: 190) { mode in
                switch mode {
                case .distanceDescending: return L("Back to Front")
                case .distanceAscending: return L("Front to Back")
                case .oldestFirst: return L("Oldest First")
                case .youngestFirst: return L("Youngest First")
                }
            }
        }
    }

    private struct InspectorParticleTextureSheetPlaybackModeValue: View {
        let binding: Binding<ParticleTextureSheetPlaybackMode>

        var body: some View {
            EnumField(value: binding, width: 170) { mode in
                switch mode {
                case .automatic: return L("Auto")
                case .lifetime: return L("Lifetime")
                case .playOnce: return L("Play Once")
                case .loop: return L("Loop")
                case .singleFrame: return L("Single Frame")
                }
            }
        }
    }

    private struct InspectorParticleRenderBoundsModeValue: View {
        let binding: Binding<ParticleRenderBoundsMode>

        var body: some View {
            EnumField(value: binding, width: 150) { mode in
                switch mode {
                case .disabled: return L("Disabled")
                case .manual: return L("Manual")
                case .automatic: return L("Automatic")
                }
            }
        }
    }

    private struct InspectorParticleForceModeValue: View {
        let binding: Binding<ParticleForceMode>

        var body: some View {
            EnumField(value: binding, width: 150) { mode in
                switch mode {
                case .none: return L("None")
                case .radial: return L("Radial")
                case .vortex: return L("Vortex")
                }
            }
        }
    }

    private struct InspectorParticleVectorFieldModeValue: View {
        let binding: Binding<ParticleVectorFieldMode>

        var body: some View {
            EnumField(value: binding, width: 150) { mode in
                switch mode {
                case .none: return L("None")
                case .uniform: return L("Uniform")
                case .curl: return L("Curl")
                }
            }
        }
    }

    private struct InspectorParticleSubEmitterTriggerValue: View {
        let binding: Binding<ParticleSubEmitterTrigger>

        var body: some View {
            EnumField(value: binding, width: 150) { trigger in
                switch trigger {
                case .none: return L("None")
                case .death: return L("Death")
                case .collision: return L("Collision")
                }
            }
        }
    }

    private struct InspectorParticleSubEmittersValue: View {
        let binding: Binding<[ParticleSubEmitter]>

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                Row(alignment: .center, spacing: 8) {
                    Text("\(binding.wrappedValue.count) \(L("Rules"))")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Spacer(minLength: 0)
                    Button(L("Add")) { appendRule() }
                        .buttonStyle(.secondary)
                        .frame(width: 56, height: 24)
                }
                .frame(height: ParticleSubEmitterEditorLayout.toolbarHeight)

                if binding.wrappedValue.isEmpty {
                    Box(direction: .column, alignItems: .center, justifyContent: .center) {
                        Text(L("No sub-emitter rules"))
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    .frame(height: ParticleSubEmitterEditorLayout.emptyHeight)
                    .background(.surface)
                    .cornerRadius(6)
                    .border(.border, width: 1)
                } else {
                    ScrollView(.vertical,
                               consumePolicy: .always,
                               scrollbarGutter: .stable) {
                        Box(direction: .column, alignItems: .stretch, spacing: ParticleSubEmitterEditorLayout.ruleGap) {
                            for index in binding.wrappedValue.indices {
                                ParticleSubEmitterRuleCard(binding: binding, index: index)
                            }
                        }
                    }
                    .frame(height: ParticleSubEmitterEditorLayout.listHeight(ruleCount: binding.wrappedValue.count))
                }
            }
            .padding(horizontal: 8, vertical: 8)
            .background(.surfaceSunken)
            .cornerRadius(6)
            .border(.border, width: 1)
            .frame(height: ParticleSubEmitterEditorLayout.valueHeight(ruleCount: binding.wrappedValue.count))
            .clipped()
        }

        private func appendRule() {
            var next = binding.wrappedValue
            next.append(ParticleSubEmitter(trigger: .death,
                                           burstCount: 8,
                                           probability: 1,
                                           maxDepth: 1,
                                           inheritVelocity: 0.25,
                                           lifetime: 0.45,
                                           startVelocity: SIMD3<Float>(0, 1.5, 0),
                                           velocityRandomness: SIMD3<Float>(0.5, 0.5, 0.5),
                                           startSize: 0.25,
                                           endSize: 0,
                                           startColor: SIMD4<Float>(1, 1, 1, 1),
                                           endColor: SIMD4<Float>(1, 1, 1, 0)))
            binding.wrappedValue = next
        }
    }

    private struct ParticleSubEmitterRuleCard: View {
        let binding: Binding<[ParticleSubEmitter]>
        let index: Int

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 7) {
                Row(alignment: .center, spacing: 8) {
                    Text("#\(index + 1)")
                        .font(.bodyStrong)
                        .foregroundColor(.onSurface)
                    Spacer(minLength: 0)
                    Button(icon: .resource(UICommonIcons.close),
                           size: 10,
                           tooltip: L("Remove rule"),
                           action: removeRule)
                    .buttonStyle(.ghost)
                    .frame(width: 24, height: 24)
                }
                .frame(height: 24)

                Row(alignment: .center, spacing: 8) {
                    labeledCompactField(L("Trigger")) {
                        EnumField(value: triggerBinding, width: 112) { trigger in
                            switch trigger {
                            case .none: return L("None")
                            case .death: return L("Death")
                            case .collision: return L("Collision")
                            }
                        }
                    }
                    labeledCompactField(L("Count")) {
                        NumberField(value: intBinding(\.burstCount),
                                    decimals: 0,
                                    size: .small,
                                    minValue: 0,
                                    maxValue: 10_000,
                                    step: 1,
                                    showsStepper: true)
                    }
                    labeledCompactField(L("Chance")) {
                        NumberField(value: floatBinding(\.probability),
                                    decimals: 2,
                                    size: .small,
                                    minValue: 0,
                                    maxValue: 1,
                                    step: 0.05,
                                    showsStepper: true)
                    }
                }

                Row(alignment: .center, spacing: 8) {
                    labeledCompactField(L("Depth")) {
                        NumberField(value: intBinding(\.maxDepth),
                                    decimals: 0,
                                    size: .small,
                                    minValue: 0,
                                    maxValue: 16,
                                    step: 1,
                                    showsStepper: true)
                    }
                    labeledCompactField(L("Inherit")) {
                        NumberField(value: floatBinding(\.inheritVelocity),
                                    decimals: 2,
                                    size: .small,
                                    minValue: 0,
                                    maxValue: 10,
                                    step: 0.05,
                                    showsStepper: true)
                    }
                    labeledCompactField(L("Life")) {
                        NumberField(value: floatBinding(\.lifetime),
                                    decimals: 2,
                                    size: .small,
                                    minValue: 0.0001,
                                    maxValue: 60,
                                    step: 0.05,
                                    showsStepper: true)
                    }
                }

                labeledWideField(L("Velocity")) {
                    Vec3Field(x: vectorBinding(\.startVelocity, axis: 0),
                              y: vectorBinding(\.startVelocity, axis: 1),
                              z: vectorBinding(\.startVelocity, axis: 2),
                              decimals: 2,
                              size: .small)
                }
                labeledWideField(L("Random")) {
                    Vec3Field(x: vectorBinding(\.velocityRandomness, axis: 0),
                              y: vectorBinding(\.velocityRandomness, axis: 1),
                              z: vectorBinding(\.velocityRandomness, axis: 2),
                              decimals: 2,
                              size: .small)
                }

                Row(alignment: .center, spacing: 8) {
                    labeledCompactField(L("Start Size")) {
                        NumberField(value: floatBinding(\.startSize),
                                    decimals: 2,
                                    size: .small,
                                    minValue: 0,
                                    maxValue: 100,
                                    step: 0.05,
                                    showsStepper: true)
                    }
                    labeledCompactField(L("End Size")) {
                        NumberField(value: floatBinding(\.endSize),
                                    decimals: 2,
                                    size: .small,
                                    minValue: 0,
                                    maxValue: 100,
                                    step: 0.05,
                                    showsStepper: true)
                    }
                }

                Row(alignment: .center, spacing: 8) {
                    labeledColorField(L("Start Color")) {
                        ColorField(color: colorBinding(isStart: true),
                                   showAlpha: true,
                                   showsInlineValues: false)
                    }
                    labeledColorField(L("End Color")) {
                        ColorField(color: colorBinding(isStart: false),
                                   showAlpha: true,
                                   showsInlineValues: false)
                    }
                }
            }
            .padding(horizontal: 8, vertical: 8)
            .background(.surface)
            .cornerRadius(6)
            .border(.border, width: 1)
            .frame(height: ParticleSubEmitterEditorLayout.ruleHeight)
            .clipped()
        }

        private func labeledCompactField<Content: View>(_ title: String,
                                                        @ViewBuilder content: () -> Content) -> some View {
            Box(direction: .column, alignItems: .stretch, spacing: 3) {
                Text(title)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                content()
                    .frame(height: 24)
                    .clipped()
            }
            .flex(1, shrink: 1, basis: 0)
        }

        private func labeledWideField<Content: View>(_ title: String,
                                                     @ViewBuilder content: () -> Content) -> some View {
            Row(alignment: .center, spacing: 8) {
                Text(title)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .frame(width: 66)
                content()
                    .flex(1, shrink: 1, basis: 0)
                    .clipped()
            }
            .frame(height: 28)
        }

        private func labeledColorField<Content: View>(_ title: String,
                                                      @ViewBuilder content: () -> Content) -> some View {
            Box(direction: .column, alignItems: .stretch, spacing: 3) {
                Text(title)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                content()
                    .frame(height: 26)
                    .clipped()
            }
            .flex(1, shrink: 1, basis: 0)
        }

        private var rule: ParticleSubEmitter? {
            guard binding.wrappedValue.indices.contains(index) else { return nil }
            return binding.wrappedValue[index]
        }

        private var triggerBinding: Binding<ParticleSubEmitterTrigger> {
            Binding(
                get: { rule?.trigger ?? .none },
                set: { value in updateRule { $0.trigger = value } }
            )
        }

        private func floatBinding(_ keyPath: WritableKeyPath<ParticleSubEmitter, Float>) -> Binding<Float> {
            Binding(
                get: { rule?[keyPath: keyPath] ?? 0 },
                set: { value in updateRule { $0[keyPath: keyPath] = value } }
            )
        }

        private func intBinding(_ keyPath: WritableKeyPath<ParticleSubEmitter, Int>) -> Binding<Float> {
            Binding(
                get: { Float(rule?[keyPath: keyPath] ?? 0) },
                set: { value in updateRule { $0[keyPath: keyPath] = Int(value.rounded()) } }
            )
        }

        private func vectorBinding(_ keyPath: WritableKeyPath<ParticleSubEmitter, SIMD3<Float>>,
                                   axis: Int) -> Binding<Float> {
            Binding(
                get: {
                    guard let rule, axis >= 0 && axis < 3 else { return 0 }
                    return rule[keyPath: keyPath][axis]
                },
                set: { value in
                    guard axis >= 0 && axis < 3 else { return }
                    updateRule { $0[keyPath: keyPath][axis] = value }
                }
            )
        }

        private func colorBinding(isStart: Bool) -> Binding<Color> {
            Binding(
                get: {
                    let color = rule.map { isStart ? $0.startColor : $0.endColor }
                        ?? SIMD4<Float>(1, 1, 1, 1)
                    return Color(r: color.x, g: color.y, b: color.z, a: color.w)
                },
                set: { value in
                    let color = SIMD4<Float>(clamp01(value.r),
                                             clamp01(value.g),
                                             clamp01(value.b),
                                             clamp01(value.a))
                    updateRule {
                        if isStart {
                            $0.startColor = color
                        } else {
                            $0.endColor = color
                        }
                    }
                }
            )
        }

        private func updateRule(_ mutate: (inout ParticleSubEmitter) -> Void) {
            guard binding.wrappedValue.indices.contains(index) else { return }
            var next = binding.wrappedValue
            mutate(&next[index])
            next[index] = sanitized(next[index])
            binding.wrappedValue = next
        }

        private func removeRule() {
            guard binding.wrappedValue.indices.contains(index) else { return }
            var next = binding.wrappedValue
            next.remove(at: index)
            binding.wrappedValue = next
        }

        private func sanitized(_ rule: ParticleSubEmitter) -> ParticleSubEmitter {
            ParticleSubEmitter(trigger: rule.trigger,
                               burstCount: rule.burstCount,
                               probability: rule.probability,
                               maxDepth: rule.maxDepth,
                               inheritVelocity: rule.inheritVelocity,
                               lifetime: rule.lifetime,
                               startVelocity: rule.startVelocity,
                               velocityRandomness: rule.velocityRandomness,
                               startSize: rule.startSize,
                               endSize: rule.endSize,
                               startColor: rule.startColor,
                               endColor: rule.endColor)
        }

        private func clamp01(_ value: Float) -> Float {
            max(0, min(1, value))
        }
    }

    private func propertySections(_ sections: [EditorInspectorSection],
                                  collapsedIDs: Set<String>,
                                  entityID: UInt64?,
                                  particleDiagnostics: InspectorParticleRuntimeDiagnostics) -> [PropertyGridSection] {
        sections.map { section in
            let startsCollapsed = collapsedIDs.contains(section.id)
            return PropertyGridSection(
                id: section.id,
                title: section.title,
                rows: section.fields.map { field in
                    PropertyGridRow(id: field.id,
                                    label: field.label,
                                    rowHeight: field.value.preferredRowHeight(defaultHeight: 28),
                                    layout: field.value.preferredRowLayout) {
                        fieldView(field.value,
                                  identity: "\(entityID.map(String.init) ?? "none")/\(section.id)/\(field.id)",
                                  particleDiagnostics: particleDiagnostics)
                    }
                },
                isCollapsible: true,
                startsCollapsed: startsCollapsed
            )
        }
    }

    private func fieldView(_ value: EditorInspectorFieldValue,
                           identity: String,
                           particleDiagnostics: InspectorParticleRuntimeDiagnostics) -> some View {
        switch value {
        case let .readOnly(text):
            return AnyView(InspectorReadOnlyValue(text: text))
        case let .text(binding):
            return AnyView(InspectorTextValue(identity: identity, binding: binding))
        case let .bool(binding):
            return AnyView(InspectorBooleanValue(binding: binding))
        case let .number(binding):
            return AnyView(InspectorNumberValue(binding: binding,
                                                minValue: nil,
                                                maxValue: nil,
                                                step: nil,
                                                showsStepper: false))
        case let .constrainedNumber(binding, min, max, step, showsStepper):
            return AnyView(InspectorNumberValue(binding: binding,
                                                minValue: min,
                                                maxValue: max,
                                                step: step,
                                                showsStepper: showsStepper))
        case let .vector3(x, y, z):
            return AnyView(InspectorVectorValue(x: x, y: y, z: z))
        case let .color(binding):
            return AnyView(InspectorColorValue(binding: binding))
        case let .json(binding, minHeight):
            return AnyView(JsonField(text: binding, minHeight: minHeight))
        case let .lightType(binding):
            return AnyView(InspectorLightTypeValue(binding: binding))
        case let .rigidBodyMotion(binding):
            return AnyView(InspectorRigidBodyMotionValue(binding: binding))
        case let .colliderShapeKind(binding):
            return AnyView(InspectorColliderShapeKindValue(binding: binding))
        case let .particleEmissionShape(binding):
            return AnyView(InspectorParticleEmissionShapeValue(binding: binding))
        case let .particleCollisionMode(binding):
            return AnyView(InspectorParticleCollisionModeValue(binding: binding))
        case let .particleSimulationSpace(binding):
            return AnyView(InspectorParticleSimulationSpaceValue(binding: binding))
        case let .particleSimulationBackend(binding):
            return AnyView(InspectorParticleSimulationBackendValue(binding: binding))
        case let .particleCurve(binding):
            return AnyView(InspectorParticleCurveValue(binding: binding))
        case let .particleBlendMode(binding):
            return AnyView(InspectorParticleBlendModeValue(binding: binding))
        case let .particleRenderMode(binding):
            return AnyView(InspectorParticleRenderModeValue(binding: binding))
        case let .particleSortMode(binding):
            return AnyView(InspectorParticleSortModeValue(binding: binding))
        case let .particleTextureSheetPlaybackMode(binding):
            return AnyView(InspectorParticleTextureSheetPlaybackModeValue(binding: binding))
        case let .particleRenderAlignment(binding):
            return AnyView(InspectorParticleRenderAlignmentValue(binding: binding))
        case let .particleRenderBoundsMode(binding):
            return AnyView(InspectorParticleRenderBoundsModeValue(binding: binding))
        case let .particleForceMode(binding):
            return AnyView(InspectorParticleForceModeValue(binding: binding))
        case let .particleVectorFieldMode(binding):
            return AnyView(InspectorParticleVectorFieldModeValue(binding: binding))
        case let .particleSubEmitterTrigger(binding):
            return AnyView(InspectorParticleSubEmitterTriggerValue(binding: binding))
        case let .particleSubEmitters(binding):
            return AnyView(InspectorParticleSubEmittersValue(binding: binding))
        case let .particleModuleStack(binding):
            return AnyView(InspectorParticleModuleStackValue(binding: binding,
                                                             diagnostics: particleDiagnostics))
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
    var preferredRowLayout: PropertyGridRowLayout {
        switch self {
        case .particleCurve, .particleSubEmitters, .particleModuleStack:
            return .fullWidth
        default:
            return .twoColumn
        }
    }

    func preferredRowHeight(defaultHeight: Float) -> Float? {
        switch self {
        case .vector3:
            return max(defaultHeight, 30)
        case .asset:
            return max(defaultHeight, 34)
        case let .particleCurve(binding):
            if case .keyframes(let keyframes) = binding.wrappedValue {
                return max(defaultHeight, ParticleCurveEditorLayout.rowHeight(keyframeCount: keyframes.count))
            }
            return max(defaultHeight, ParticleCurveEditorLayout.linearRowHeight)
        case let .particleSubEmitters(binding):
            return max(defaultHeight, ParticleSubEmitterEditorLayout.rowHeight(ruleCount: binding.wrappedValue.count))
        case let .particleModuleStack(binding):
            let stack = binding.wrappedValue
            let headerHeight: Float = 43
            let summaryHeight: Float = 23
            let groupHeaderHeight: Float = 24
            let rowHeight: Float = 47
            let moduleEditorRowHeight: Float = 50
            let moduleExpandedHeaderHeight: Float = 58
            let moduleGPUBackendPanelHeight: Float = 90
            let moduleExpandedDiagnosticsHeight: Float = 43
            let moduleIssueHeaderHeight: Float = 18
            let moduleIssueRowHeight: Float = 30
            let advancedModuleIDs: Set<String> = [
                "textureSheet",
                "trails",
                "subEmitters",
                "gpuSimulation",
            ]
            let stackIssueCounts = Dictionary(
                grouping: stack.validationIssues(),
                by: \.moduleID
            ).mapValues(\.count)
            let groupCount: Float = stack.modules.contains { advancedModuleIDs.contains($0.id) } ? 2 : 1
            let expandedEditorHeight = stack.modules.reduce(Float(0)) { total, module in
                guard module.isExpanded else { return total }
                let issueCount = Float(stackIssueCounts[module.id] ?? 0)
                let issueHeight = issueCount > 0
                    ? moduleIssueHeaderHeight + issueCount * moduleIssueRowHeight
                    : 0
                let gpuBackendHeight: Float
                if case .gpuSimulation = module.settings {
                    gpuBackendHeight = moduleGPUBackendPanelHeight
                } else {
                    gpuBackendHeight = 0
                }
                return total
                    + 8
                    + moduleExpandedHeaderHeight
                    + particleModuleEditorHeight(module.settings, rowHeight: moduleEditorRowHeight)
                    + gpuBackendHeight
                    + issueHeight
                    + moduleExpandedDiagnosticsHeight
            }
            let groupSpacing: Float = max(0, groupCount - 1) * 4
            let rowSpacing: Float = Float(max(0, stack.modules.count - Int(groupCount))) * 3
            let cardPadding: Float = 16
            return max(defaultHeight,
                       headerHeight
                       + summaryHeight
                       + groupCount * groupHeaderHeight
                       + Float(stack.modules.count) * rowHeight
                       + expandedEditorHeight
                       + groupSpacing
                       + rowSpacing
                       + cardPadding
                       + 8)
        case let .json(_, minHeight):
            return max(defaultHeight, minHeight + 34)
        default:
            return nil
        }
    }
}

private func particleModuleEditorHeight(_ settings: ParticleEmitterModuleSettings,
                                        rowHeight: Float) -> Float {
    if case let .subEmitters(module) = settings {
        return 2 * rowHeight
            + 5
            + ParticleSubEmitterEditorLayout.propertyGridLabelHeight
            + 4
            + ParticleSubEmitterEditorLayout.valueHeight(ruleCount: module.rules.count)
    }
    return Float(particleModuleEditorRowCount(settings)) * rowHeight
}

private func particleModuleEditorRowCount(_ settings: ParticleEmitterModuleSettings) -> Int {
    switch settings {
    case .forces:
        return 6
    case .appearance:
        return 5
    case .renderer, .trails:
        return 5
    case .shape:
        return 4
    case .textureSheet:
        return 3
    case .collision, .gpuSimulation, .subEmitters, .velocity:
        return 2
    default:
        return 1
    }
}

private enum ParticleCurveEditorLayout {
    static let cardVerticalPadding: Float = 8
    static let contentGap: Float = 7
    static let toolbarHeight: Float = 32
    static let previewHeight: Float = 72
    static let keyframeHeaderHeight: Float = 20
    static let keyframeEntryHeight: Float = 24
    static let keyframeRowGap: Float = 4
    static let propertyGridLabelHeight: Float = 18
    static let propertyGridVerticalPadding: Float = 6
    static let linearValueHeight: Float = cardVerticalPadding * 2 + toolbarHeight
    static let linearRowHeight: Float = propertyGridLabelHeight
        + propertyGridVerticalPadding * 2
        + linearValueHeight

    static func keyframeEntryListHeight(keyframeCount: Int) -> Float {
        guard keyframeCount > 0 else { return 0 }
        let rows = Float(keyframeCount) * keyframeEntryHeight
        let gaps = Float(max(0, keyframeCount - 1)) * keyframeRowGap
        return rows + gaps
    }

    static func keyframeRowsHeight(keyframeCount: Int) -> Float {
        keyframeHeaderHeight
            + keyframeRowGap
            + keyframeEntryListHeight(keyframeCount: keyframeCount)
    }

    static func valueHeight(keyframeCount: Int) -> Float {
        cardVerticalPadding * 2
            + toolbarHeight
            + contentGap
            + previewHeight
            + contentGap
            + keyframeRowsHeight(keyframeCount: keyframeCount)
    }

    static func rowHeight(keyframeCount: Int) -> Float {
        propertyGridLabelHeight
            + propertyGridVerticalPadding * 2
            + valueHeight(keyframeCount: keyframeCount)
    }
}

private enum ParticleSubEmitterEditorLayout {
    static let cardVerticalPadding: Float = 8
    static let propertyGridLabelHeight: Float = 18
    static let propertyGridVerticalPadding: Float = 6
    static let toolbarHeight: Float = 24
    static let emptyHeight: Float = 42
    static let ruleHeight: Float = 236
    static let ruleGap: Float = 8
    static let maxVisibleRules = 2

    static func listHeight(ruleCount: Int) -> Float {
        guard ruleCount > 0 else { return emptyHeight }
        let visibleRules = min(ruleCount, maxVisibleRules)
        let rulesHeight = Float(visibleRules) * ruleHeight
        let gapsHeight = Float(max(0, visibleRules - 1)) * ruleGap
        return rulesHeight + gapsHeight
    }

    static func contentHeight(ruleCount: Int) -> Float {
        let bodyHeight = ruleCount == 0 ? emptyHeight : listHeight(ruleCount: ruleCount)
        return cardVerticalPadding * 2
            + toolbarHeight
            + ruleGap
            + bodyHeight
    }

    static func valueHeight(ruleCount: Int) -> Float {
        contentHeight(ruleCount: ruleCount)
    }

    static func rowHeight(ruleCount: Int) -> Float {
        propertyGridLabelHeight
            + propertyGridVerticalPadding * 2
            + valueHeight(ruleCount: ruleCount)
    }
}

private struct ParticleCurveKeyframeRows: View {
    let binding: Binding<ParticleCurve>
    let keyframes: [ParticleCurveKeyframe]
    let selectedKeyIndex: Binding<Int?>

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: ParticleCurveEditorLayout.keyframeRowGap) {
            Row(alignment: .center, spacing: 6) {
                Text("")
                    .frame(width: 30)
                Text(L("Time"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .frame(width: 74)
                Text(L("Value"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .frame(width: 74)
                Spacer(minLength: 0)
            }
            .frame(height: ParticleCurveEditorLayout.keyframeHeaderHeight)
            ParticleCurveKeyframeEntryList(binding: binding,
                                           keyframes: keyframes,
                                           selectedKeyIndex: selectedKeyIndex)
        }
        .frame(height: ParticleCurveEditorLayout.keyframeRowsHeight(keyframeCount: keyframes.count))
        .padding(horizontal: 1, vertical: 0)
        .clipped()
    }
}

private struct ParticleCurveKeyframeEntryList: _PrimitiveView {
    let binding: Binding<ParticleCurve>
    let keyframes: [ParticleCurveKeyframe]
    let selectedKeyIndex: Binding<Int?>

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {}

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.height = ParticleCurveEditorLayout.keyframeEntryListHeight(keyframeCount: keyframes.count)
        layout.setGap(ParticleCurveEditorLayout.keyframeRowGap, gutter: .all)
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.height = ParticleCurveEditorLayout.keyframeEntryListHeight(keyframeCount: keyframes.count)
        layout.setGap(ParticleCurveEditorLayout.keyframeRowGap, gutter: .all)
    }

    var _children: [any View] {
        (0..<keyframes.count).map { index in
            AnyView(
                Row(alignment: .center, spacing: 6) {
                    Button(isSelected: selectedKeyIndex.wrappedValue == index,
                           tooltip: L("Select keyframe"),
                           action: { selectedKeyIndex.wrappedValue = index }) {
                        Text("\(index + 1)")
                    }
                    .buttonStyle(.toggle)
                    .frame(width: 30, height: 22)
                    NumberField(value: keyTimeBinding(index: index),
                                decimals: 2,
                                size: .small,
                                minValue: 0,
                                maxValue: 1,
                                step: 0.01,
                                showsStepper: true)
                    .frame(width: 74)
                    NumberField(value: keyValueBinding(index: index),
                                decimals: 2,
                                size: .small,
                                minValue: -4,
                                maxValue: 4,
                                step: 0.05,
                                showsStepper: true)
                    .frame(width: 74)
                    Button(icon: .resource(UICommonIcons.close),
                           size: 10,
                           isEnabled: keyframes.count > 2,
                           tooltip: L("Remove keyframe"),
                           action: { removeKeyframe(at: index) })
                    .buttonStyle(.ghost)
                    .frame(width: 22, height: 22)
                    Spacer(minLength: 0)
                }
                .frame(height: ParticleCurveEditorLayout.keyframeEntryHeight)
            )
        }
    }

    private func keyTimeBinding(index: Int) -> Binding<Float> {
        Binding<Float>(
            get: {
                guard case .keyframes(let keys) = binding.wrappedValue,
                      keys.indices.contains(index)
                else { return 0 }
                return keys[index].time
            },
            set: { value in
                updateKeyframe(at: index) { key in
                    key.time = min(max(value, 0), 1)
                }
            }
        )
    }

    private func keyValueBinding(index: Int) -> Binding<Float> {
        Binding<Float>(
            get: {
                guard case .keyframes(let keys) = binding.wrappedValue,
                      keys.indices.contains(index)
                else { return 0 }
                return keys[index].value
            },
            set: { value in
                updateKeyframe(at: index) { key in
                    key.value = value
                }
            }
        )
    }

    private func updateKeyframe(at index: Int,
                                mutate: (inout ParticleCurveKeyframe) -> Void) {
        guard case .keyframes(var keys) = binding.wrappedValue,
              keys.indices.contains(index)
        else { return }
        mutate(&keys[index])
        let editedKey = keys[index]
        let sorted = keys.sortedByTimeStable()
        binding.wrappedValue = .keyframes(sorted)
        selectedKeyIndex.wrappedValue = sorted.nearestIndex(to: editedKey)
    }

    private func removeKeyframe(at index: Int) {
        guard keyframes.count > 2, keyframes.indices.contains(index) else { return }
        var next = keyframes
        next.remove(at: index)
        binding.wrappedValue = .keyframes(next.sortedByTimeStable())
        selectedKeyIndex.wrappedValue = next.isEmpty ? nil : min(index, next.count - 1)
    }
}

private struct ParticleCurvePreview: View {
    let binding: Binding<ParticleCurve>
    let selectedKeyIndex: Binding<Int?>

    var body: some View {
        ParticleCurvePreviewHost(binding: binding, selectedKeyIndex: selectedKeyIndex)
            .frame(minWidth: 120, minHeight: 44)
    }
}

private struct ParticleCurvePreviewHost: _PrimitiveView {
    let binding: Binding<ParticleCurve>
    let selectedKeyIndex: Binding<Int?>

    private static let activeKeyIndex = "__particle_curve_active_key_index"

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        return node
    }

    func _updateNode(_ node: Node) {
        let snapshot = self
        node.cursor = .pointer
        node.draw = { list, origin in
            snapshot.render(node: node, origin: origin, list: list)
        }

        guard let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        registry.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                PointerCaptureHolder.current?.acquire(node)
                let graph = snapshot.graphRect(for: node)
                let index = snapshot.pickOrInsertKey(windowX: event.x, windowY: event.y, graph: graph)
                let nextIndex = snapshot.writeKey(at: index,
                                                  windowX: event.x,
                                                  windowY: event.y,
                                                  graph: graph) ?? index
                node.attachments[Self.activeKeyIndex] = nextIndex
                snapshot.selectedKeyIndex.wrappedValue = nextIndex
                return .handled
            case .up:
                if let index = node.attachments[Self.activeKeyIndex] as? Int {
                    snapshot.selectedKeyIndex.wrappedValue = index
                }
                node.attachments[Self.activeKeyIndex] = nil
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                return .handled
            }
        }
        registry.setMotion(node) { event, _ in
            guard PointerCaptureHolder.current?.target === node,
                  let index = node.attachments[Self.activeKeyIndex] as? Int
            else { return .ignored }
            if let nextIndex = snapshot.writeKey(at: index,
                                                 windowX: event.x,
                                                 windowY: event.y,
                                                 graph: snapshot.graphRect(for: node)) {
                node.attachments[Self.activeKeyIndex] = nextIndex
                snapshot.selectedKeyIndex.wrappedValue = nextIndex
            }
            return .handled
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.height = ParticleCurveEditorLayout.previewHeight
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.height = ParticleCurveEditorLayout.previewHeight
    }

    private func render(node: Node, origin: CGPoint, list: DrawList) {
        let width = Float(node.frame.width)
        let height = Float(node.frame.height)
        guard width > 2, height > 2 else { return }

        let curve = binding.wrappedValue
        let colors = node.theme.colors
        let x = Float(origin.x)
        let y = Float(origin.y)
        let rect = UIRect(x: x, y: y, width: width, height: height)
        list.addRoundedRect(rect, radius: 5, color: colors.surfaceSunken)
        drawBorder(rect: rect, color: colors.border, list: list)

        let inset: Float = 6
        let graph = UIRect(x: x + inset,
                           y: y + inset,
                           width: max(1, width - inset * 2),
                           height: max(1, height - inset * 2))

        for fraction in [Float(0.25), Float(0.5), Float(0.75)] {
            let gx = graph.minX + graph.width * fraction
            list.addRect(UIRect(x: gx, y: graph.minY, width: 1, height: graph.height),
                         color: colors.divider)
            let gy = graph.minY + graph.height * fraction
            list.addRect(UIRect(x: graph.minX, y: gy, width: graph.width, height: 1),
                         color: colors.divider)
        }

        let samples = 28
        var previous: (x: Float, y: Float)?
        for sample in 0...samples {
            let t = Float(sample) / Float(samples)
            let value = curve.evaluate(at: t)
            let px = graph.minX + t * graph.width
            let py = graph.maxY - min(max(value, 0), 1) * graph.height
            if let previous {
                list.addLine(fromX: previous.x, fromY: previous.y,
                             toX: px, toY: py,
                             thickness: 2,
                             color: colors.accent)
            }
            previous = (px, py)
        }

        if case .keyframes(let keyframes) = curve {
            let active = node.attachments[Self.activeKeyIndex] as? Int ?? selectedKeyIndex.wrappedValue
            for (index, key) in keyframes.enumerated() {
                let px = graph.minX + key.time * graph.width
                let py = graph.maxY - min(max(key.value, 0), 1) * graph.height
                let radius: Float = active == index ? 3.5 : 2.5
                let marker = UIRect(x: px - radius,
                                    y: py - radius,
                                    width: radius * 2,
                                    height: radius * 2)
                list.addRoundedRect(marker,
                                    radius: radius,
                                    color: active == index ? colors.warning : colors.accentSecondary)
            }
        }
    }

    private func graphRect(for node: Node) -> UIRect {
        let inset: Float = 6
        let x = Float(node.absoluteOrigin.x)
        let y = Float(node.absoluteOrigin.y)
        let width = max(1, Float(node.frame.width) - inset * 2)
        let height = max(1, Float(node.frame.height) - inset * 2)
        return UIRect(x: x + inset, y: y + inset, width: width, height: height)
    }

    private func pickOrInsertKey(windowX: Float, windowY: Float, graph: UIRect) -> Int {
        guard case .keyframes(let keyframes) = binding.wrappedValue else { return 0 }
        if let index = nearestKeyIndex(windowX: windowX, windowY: windowY, graph: graph, keyframes: keyframes) {
            return index
        }

        var next = keyframes
        let key = keyframe(windowX: windowX, windowY: windowY, graph: graph)
        next.append(key)
        let sorted = next.sortedByTimeStable()
        binding.wrappedValue = .keyframes(sorted)
        let index = nearestKeyIndex(windowX: windowX,
                                    windowY: windowY,
                                    graph: graph,
                                    keyframes: sorted) ?? max(0, sorted.count - 1)
        selectedKeyIndex.wrappedValue = index
        return index
    }

    private func nearestKeyIndex(windowX: Float,
                                 windowY: Float,
                                 graph: UIRect,
                                 keyframes: [ParticleCurveKeyframe]) -> Int? {
        let thresholdSquared: Float = 64
        var best: (index: Int, distance: Float)?
        for (index, key) in keyframes.enumerated() {
            let px = graph.minX + key.time * graph.width
            let py = graph.maxY - min(max(key.value, 0), 1) * graph.height
            let dx = px - windowX
            let dy = py - windowY
            let distance = dx * dx + dy * dy
            if distance <= thresholdSquared, best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func writeKey(at index: Int, windowX: Float, windowY: Float, graph: UIRect) -> Int? {
        guard case .keyframes(var keyframes) = binding.wrappedValue,
              keyframes.indices.contains(index)
        else { return nil }
        keyframes[index] = keyframe(windowX: windowX, windowY: windowY, graph: graph)
        let sorted = keyframes.sortedByTimeStable()
        binding.wrappedValue = .keyframes(sorted)
        let nextIndex = nearestKeyIndex(windowX: windowX,
                                        windowY: windowY,
                                        graph: graph,
                                        keyframes: sorted)
        selectedKeyIndex.wrappedValue = nextIndex
        return nextIndex
    }

    private func keyframe(windowX: Float, windowY: Float, graph: UIRect) -> ParticleCurveKeyframe {
        let time = min(max((windowX - graph.minX) / max(1, graph.width), 0), 1)
        let value = min(max((graph.maxY - windowY) / max(1, graph.height), 0), 1)
        return ParticleCurveKeyframe(time: time, value: value)
    }

    private func drawBorder(rect: UIRect, color: Color, list: DrawList) {
        list.addRect(UIRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1), color: color)
        list.addRect(UIRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1), color: color)
        list.addRect(UIRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height), color: color)
        list.addRect(UIRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height), color: color)
    }
}

private extension Array where Element == ParticleCurveKeyframe {
    func sortedByTimeStable() -> [ParticleCurveKeyframe] {
        enumerated()
            .sorted {
                if $0.element.time == $1.element.time {
                    return $0.offset < $1.offset
                }
                return $0.element.time < $1.element.time
            }
            .map(\.element)
    }

    func nearestIndex(to keyframe: ParticleCurveKeyframe) -> Int? {
        guard !isEmpty else { return nil }
        return indices.min { lhs, rhs in
            let left = distanceSquared(self[lhs], keyframe)
            let right = distanceSquared(self[rhs], keyframe)
            return left < right
        }
    }

    private func distanceSquared(_ lhs: ParticleCurveKeyframe, _ rhs: ParticleCurveKeyframe) -> Float {
        let dt = lhs.time - rhs.time
        let dv = lhs.value - rhs.value
        return dt * dt + dv * dv
    }
}

/// Inspector affordance that surfaces `EditorSceneAdapter.addComponent`, so any
/// supported component (Particle Emitter, Rigid Body, Audio Source, …) can be
/// added to the selected entity. Hidden when every kind is already present.
private struct AddComponentButton: View {
    let scene: EditorSceneAdapter
    let entityID: UInt64
    @State private var isPresented: Bool = false

    var body: some View {
        let kinds = scene.addableComponentKinds(on: entityID)
        return Box(direction: .column, alignItems: .flexStart) {
            if !kinds.isEmpty {
                Popover(isPresented: $isPresented, width: 200) {
                    Row(alignment: .center, spacing: 6) {
                        Text("+", lineLimit: 1)
                            .font(.bodyStrong)
                            .foregroundColor(.accent)
                        Text(L("Add Component"), lineLimit: 1)
                            .font(.caption)
                            .foregroundColor(.onSurface)
                    }
                    .padding(horizontal: 10, vertical: 6)
                    .background(.surfaceSunken)
                    .cornerRadius(4)
                } content: {
                    Menu(kinds.map { kind in
                        MenuEntry.item(MenuItem(id: "add-component-\(kind.rawValue)",
                                                title: L(kind.displayName),
                                                action: { scene.addComponent(kind, to: entityID) }))
                    }, width: 200, maxVisibleRows: 10, onItemActivated: {
                        isPresented = false
                    })
                }
            }
        }
        .padding(horizontal: 6, vertical: 4)
    }
}
