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

    var liveBudgetLimit: Int {
        selectedFrameStats?.liveParticleBudgetLimit ?? frameStats.liveParticleBudgetLimit
    }

    var liveBudgetText: String {
        liveBudgetLimit > 0 ? "\(liveParticleCount)/\(liveBudgetLimit)" : "\(liveParticleCount)"
    }

    var liveBudgetPressure: Float {
        selectedFrameStats?.liveParticleBudgetUtilization ?? frameStats.liveParticleBudgetUtilization
    }

    var runtimePressureLevel: ParticleRuntimePressureLevel {
        selectedFrameStats?.runtimePressureLevel ?? frameStats.runtimePressureLevel
    }

    var simulatedDeltaTime: Float {
        selectedFrameStats?.simulatedDeltaTime ?? frameStats.simulatedDeltaTime
    }

    var spawnedParticleCount: Int {
        selectedFrameStats?.spawnedParticleCount ?? frameStats.spawnedParticleCount
    }

    var requestedSpawnCount: Int {
        selectedFrameStats?.requestedSpawnCount ?? frameStats.requestedSpawnCount
    }

    var spawnBudgetLimit: Int {
        selectedFrameStats?.spawnBudgetLimit ?? frameStats.spawnBudgetLimit
    }

    var spawnBudgetConsumedCount: Int {
        selectedFrameStats?.spawnBudgetConsumedCount ?? frameStats.spawnBudgetConsumedCount
    }

    var spawnBudgetText: String {
        spawnBudgetLimit > 0 ? "\(spawnBudgetConsumedCount)/\(spawnBudgetLimit)" : "\(spawnBudgetConsumedCount)/unlimited"
    }

    var capacityLimitedSpawnCount: Int {
        selectedFrameStats?.capacityLimitedSpawnCount ?? frameStats.capacityLimitedSpawnCount
    }

    var spawnBudgetLimitedCount: Int {
        selectedFrameStats?.spawnBudgetLimitedCount ?? frameStats.spawnBudgetLimitedCount
    }

    var droppedSpawnCount: Int {
        selectedFrameStats?.droppedSpawnCount ?? frameStats.droppedSpawnCount
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

    var eventSpawnBudgetLimitedCount: Int {
        selectedEventStats?.spawnBudgetLimitedCount ?? eventReport.spawnBudgetLimitedCount
    }

    var eventDroppedSpawnCount: Int {
        selectedEventStats?.droppedSpawnCount ?? eventReport.droppedSpawnCount
    }

    var eventRequestedSpawnCount: Int {
        selectedEventStats?.requestedSpawnCount ?? eventReport.requestedSpawnCount
    }

    var eventSpawnBudgetLimit: Int {
        selectedEventStats?.spawnBudgetLimit ?? eventReport.spawnBudgetLimit
    }

    var eventSpawnBudgetConsumedCount: Int {
        selectedEventStats?.spawnBudgetConsumedCount ?? eventReport.spawnBudgetConsumedCount
    }

    var eventSpawnBudgetText: String {
        eventSpawnBudgetLimit > 0
            ? "\(eventSpawnBudgetConsumedCount)/\(eventSpawnBudgetLimit)"
            : "\(eventSpawnBudgetConsumedCount)/unlimited"
    }

    var runtimeDropCount: Int {
        droppedSpawnCount
            + eventDroppedSpawnCount
            + eventReport.droppedReadbackEventCount
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
        private static let stageBadgeWidth: Float = 58

        let binding: Binding<ParticleModuleStack>
        let diagnostics: InspectorParticleRuntimeDiagnostics

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

        private var modifiedModuleCount: Int {
            stack.modifiedModuleIDs.count
        }

        private var coreModuleIndices: [Int] {
            stack.modules.indices.filter { !isAdvancedModule(stack.modules[$0]) }
        }

        private var advancedModuleIndices: [Int] {
            stack.modules.indices.filter { isAdvancedModule(stack.modules[$0]) }
        }

        private var hasValidationIssues: Bool {
            !diagnostics.moduleValidationIssues.isEmpty || !stack.validationIssues().isEmpty
        }

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                Box(direction: .column, alignItems: .stretch, spacing: 6) {
                    Row(alignment: .center, spacing: 8) {
                        Text(L("Modules"))
                            .lineLimit(1)
                            .font(.bodyStrong)
                            .foregroundColor(.onSurface)
                            .flex()

                        Button(L("Reset"),
                               tooltip: L("Reset module order and enabled states")) {
                            var stack = binding.wrappedValue
                            stack.resetAuthoringState()
                            binding.wrappedValue = stack
                        }
                        .buttonStyle(GhostButtonStyle())
                    }

                    Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 6) {
                        summaryChip("\(L("Active"))  \(enabledModuleCount) / \(stack.modules.count)",
                                    foreground: .info,
                                    background: .info.opacity(0.12))
                        summaryChip(gpuSummaryText,
                                    foreground: gpuSummaryForeground,
                                    background: gpuSummaryBackground)
                        summaryChip("\(L("Advanced"))  \(advancedModuleCount)")

                        if modifiedModuleCount > 0 {
                            Button("\(L("Modified"))  \(modifiedModuleCount)",
                                   tooltip: L("Expand modified modules")) {
                                var stack = binding.wrappedValue
                                stack.expandModifiedModules(collapseOthers: true)
                                binding.wrappedValue = stack
                            }
                            .buttonStyle(GhostButtonStyle())
                        }

                        if hasValidationIssues {
                            Button(L("Issues"),
                                   tooltip: L("Expand modules with validation issues")) {
                                var stack = binding.wrappedValue
                                let issueModuleIDs = diagnostics.moduleValidationIssues.map(\.moduleID)
                                    + stack.validationIssues().map(\.moduleID)
                                stack.expandModules(withIDs: issueModuleIDs, collapseOthers: true)
                                binding.wrappedValue = stack
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                    }
                    .debugName("particle-module-stack-summary")
                }

                BoundedScrollView(.vertical,
                                  contentHeight: moduleListContentHeight,
                                  minHeight: ParticleModuleStackLayout.minListViewportHeight,
                                  maxHeight: ParticleModuleStackLayout.maxListViewportHeight) {
                    moduleList()
                }
                .background(.surfaceSunken)
                .cornerRadius(4)
                .border(.divider, width: 1)
                .debugName("particle-module-stack-list-scroll")
            }
            .padding(horizontal: 8, vertical: 8)
            .background(.surface)
            .cornerRadius(6)
            .border(.divider, width: 1)
            .debugName("particle-module-stack")
        }

        private var moduleListContentHeight: Float {
            let issueCounts = Dictionary(
                grouping: stack.modules.map { module in
                    (module.id, moduleValidationIssues(for: module.id).count)
                },
                by: { $0.0 }
            ).mapValues { entries in entries.reduce(0) { $0 + $1.1 } }
            return ParticleModuleStackLayout.listContentHeight(stack: stack,
                                                               issueCountsByModuleID: issueCounts)
        }

        private func moduleList() -> some View {
            Box(direction: .column, alignItems: .stretch, spacing: ParticleModuleStackLayout.groupSpacing) {
                moduleGroup(title: L("Core"),
                            subtitle: "\(enabledCount(in: coreModuleIndices))/\(coreModuleIndices.count)",
                            indices: coreModuleIndices)

                if !advancedModuleIndices.isEmpty {
                    moduleGroup(title: L("Advanced"),
                                subtitle: "\(enabledCount(in: advancedModuleIndices))/\(advancedModuleIndices.count)",
                                indices: advancedModuleIndices)
                }
            }
            .padding(horizontal: 6, vertical: 6)
            .debugName("particle-module-stack-list")
        }

        private var gpuSummaryText: String {
            gpuSummaryStatus.text
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
                .padding(horizontal: 7, vertical: 2)
                .background(background)
                .cornerRadius(3)
                .border(foreground.opacity(0.10), width: 1)
        }

        private func moduleGroup(title: String, subtitle: String, indices: [Int]) -> AnyView {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 4) {
                if isAdvancedGroup(title: title) {
                    Row(alignment: .center, spacing: 10) {
                        Box { EmptyView() }
                            .frame(height: 1)
                            .background(.divider)
                            .flex()
                        Text(title)
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                        Box { EmptyView() }
                            .frame(height: 1)
                            .background(.divider)
                            .flex()
                    }
                    .padding(horizontal: 14, vertical: 8)
                }

                Box(direction: .column, alignItems: .stretch, spacing: 3) {
                    for index in indices {
                        moduleRow(index)
                    }
                }
            })
        }

        private func moduleRow(_ index: Int) -> AnyView {
            let module = stack.modules[index]
            let isModified = stack.moduleSettingsDifferFromDefault(module.id)
            let issues = moduleValidationIssues(for: module.id)
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Row(alignment: .center, spacing: 8) {
                    Button(icon: .resource(module.isExpanded ? UICommonIcons.chevronDown : UICommonIcons.chevronRight),
                           size: 9,
                           tooltip: module.isExpanded ? L("Collapse module") : L("Expand module")) {
                        toggleModuleExpanded(index)
                    }
                    .frame(width: 22)
                    .buttonStyle(GhostButtonStyle())

                    Checkbox(isOn: moduleEnabledBinding(index))
                        .frame(width: 22)

                    Box { EmptyView() }
                        .frame(width: 3, height: 30)
                        .background(moduleAccent(module))
                        .cornerRadius(2)
                        .opacity(module.isEnabled ? 0.85 : 0.35)

                    Box(direction: .column, alignItems: .stretch, spacing: 4) {
                        Row(alignment: .center, spacing: 7) {
                            moduleStageBadge(module)

                            Text(module.displayName)
                                .lineLimit(1)
                                .font(.bodyStrong)
                                .foregroundColor(module.isEnabled ? .onSurface : .onSurfaceMuted)
                                .flex()
                                .debugName("particle-module-name-\(module.id)")

                            if let badge = moduleRowStatusBadge(module,
                                                                issues: issues,
                                                                isModified: isModified) {
                                badge
                            }
                        }

                        Row(alignment: .center, spacing: 6) {
                            Text(moduleDetail(module.settings))
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundColor(module.isEnabled ? .onSurfaceVariant : .onSurfaceMuted)
                                .flex()
                                .debugName("particle-module-detail-\(module.id)")
                        }
                    }
                    .opacity(module.isEnabled ? 1 : 0.62)
                    .frame(minWidth: 0)
                    .flex()
                }
                .padding(horizontal: 8, vertical: 7)
                .background(moduleHeaderBackground(module))

                if module.isExpanded {
                    expandedModuleEditor(index: index, module: module)
                }
            }
            .background(moduleBackground(module))
            .cornerRadius(5)
            .border(moduleBorder(module), width: 1)
            .debugName("particle-module-row-\(module.id)"))
        }

        private func isAdvancedGroup(title: String) -> Bool {
            title == L("Advanced")
        }

        private func moduleHeaderBackground(_ module: ParticleEmitterModule) -> SemanticColorRef {
            if !module.isEnabled { return .surfaceSunken }
            return .surface
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
                .border(foreground.opacity(0.10), width: 1)
        }

        private func moduleStageBadge(_ module: ParticleEmitterModule) -> AnyView {
            let accent = moduleStageAccent(module.stage)
            return AnyView(Text(moduleStageLabel(module.stage))
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(accent)
                .padding(horizontal: 0, vertical: 0)
                .frame(width: Self.stageBadgeWidth))
        }

        private func moduleStageLabel(_ stage: ParticleModuleStage) -> String {
            switch stage {
            case .spawn:
                return L("Spawn")
            case .initialize:
                return L("Init")
            case .update:
                return L("Update")
            case .render:
                return L("Render")
            case .event:
                return L("Event")
            case .simulation:
                return L("System")
            }
        }

        private func moduleStageAccent(_ stage: ParticleModuleStage) -> SemanticColorRef {
            switch stage {
            case .spawn, .simulation:
                return .accentSecondary
            case .initialize, .event:
                return .info
            case .update:
                return .success
            case .render:
                return .warning
            }
        }

        private func moduleRowStatusBadge(_ module: ParticleEmitterModule,
                                          issues: [ParticleModuleIssue],
                                          isModified: Bool) -> AnyView? {
            if let severity = highestIssueSeverity(issues) {
                let tone = moduleIssueTone(severity)
                return AnyView(statusBadge(moduleIssueSeverityLabel(severity),
                                           foreground: tone.foreground,
                                           background: tone.background))
            }
            if !module.isEnabled {
                return AnyView(statusBadge(L("Off"),
                                           foreground: .onSurfaceMuted,
                                           background: .surfaceSunken))
            }
            if isModified {
                return AnyView(statusBadge(L("Modified"),
                                           foreground: .info,
                                           background: .info.opacity(0.10)))
            }
            if module.id == "gpuSimulation" {
                let status = moduleBackendStatus(module)
                return AnyView(statusBadge(status.text,
                                           foreground: status.tone.foreground,
                                           background: status.tone.background))
            }
            return nil
        }

        private func statusBadge(_ text: String,
                                 foreground: SemanticColorRef,
                                 background: SemanticColorRef) -> some View {
            Text(text)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(foreground)
                .padding(horizontal: 6, vertical: 1)
                .background(background)
                .cornerRadius(3)
                .border(foreground.opacity(0.10), width: 1)
        }

        private func moduleValidationIssues(for moduleID: String) -> [ParticleModuleIssue] {
            diagnostics.validationIssues(for: moduleID)
                + stack.validationIssues().filter { $0.moduleID == moduleID }
        }

        private func highestIssueSeverity(_ issues: [ParticleModuleIssue]) -> ParticleModuleIssueSeverity? {
            if issues.contains(where: { $0.severity == .error }) {
                return .error
            }
            if issues.contains(where: { $0.severity == .warning }) {
                return .warning
            }
            if issues.contains(where: { $0.severity == .info }) {
                return .info
            }
            return nil
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
                if let status = spawnDropStatus(total: diagnostics.droppedSpawnCount,
                                                budget: diagnostics.spawnBudgetLimitedCount,
                                                capacity: diagnostics.capacityLimitedSpawnCount) {
                    return status
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
                if let status = spawnDropStatus(total: diagnostics.droppedSpawnCount,
                                                budget: diagnostics.spawnBudgetLimitedCount,
                                                capacity: diagnostics.capacityLimitedSpawnCount) {
                    return status
                }
                if diagnostics.scalability.pressure > 0 {
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
                if let status = spawnDropStatus(total: diagnostics.eventDroppedSpawnCount,
                                                budget: diagnostics.eventSpawnBudgetLimitedCount,
                                                capacity: diagnostics.eventCapacityLimitedSpawnCount) {
                    return status
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

        private func spawnDropStatus(total: Int,
                                     budget: Int,
                                     capacity: Int) -> ModuleRuntimeStatus? {
            guard total > 0 else { return nil }
            if budget > 0 && capacity > 0 {
                return ModuleRuntimeStatus(text: L("Mixed Drop"), tone: .warning)
            }
            if budget > 0 {
                return ModuleRuntimeStatus(text: L("Budget Drop"), tone: .warning)
            }
            if capacity > 0 {
                return ModuleRuntimeStatus(text: L("Capacity Drop"), tone: .warning)
            }
            return ModuleRuntimeStatus(text: L("Dropping"), tone: .warning)
        }

        private func moduleAccent(_ module: ParticleEmitterModule) -> SemanticColorRef {
            guard module.isEnabled else { return .divider }
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
            return module.isExpanded ? .surfaceRaised : .surface
        }

        private func moduleBorder(_ module: ParticleEmitterModule) -> SemanticColorRef {
            let issues = moduleValidationIssues(for: module.id)
            if !module.isEnabled { return .divider }
            if issues.contains(where: { $0.severity == .error }) {
                return .error
            }
            if issues.contains(where: { $0.severity == .warning }) {
                return .warning
            }
            return module.isExpanded ? .borderStrong : .divider
        }

        private func toggleModuleExpanded(_ index: Int) {
            var stack = binding.wrappedValue
            guard stack.modules.indices.contains(index) else { return }
            stack.modules[index].isExpanded.toggle()
            binding.wrappedValue = stack
        }

        private func expandedModuleEditor(index: Int, module: ParticleEmitterModule) -> AnyView {
            let issues = moduleValidationIssues(for: module.id)
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 7) {
                moduleParameterSurface(index: index, module: module)

                if case .gpuSimulation = module.settings {
                    gpuBackendStatusPanel(module)
                }

                if !issues.isEmpty {
                    moduleIssueDetails(issues)
                }
            }
            .padding(horizontal: 8, vertical: 8)
            .background(.surface)
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

        private func moduleParameterSurface(index: Int, module: ParticleEmitterModule) -> AnyView {
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 6) {
                Row(alignment: .center, spacing: 6) {
                    Text(moduleParameterSummary(module))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .flex()

                    if !module.isEnabled {
                        badge(L("Disabled"))
                    }
                }

                moduleEditor(index: index, module: module)
                    .opacity(module.isEnabled ? 1 : 0.66)
            }
            .padding(horizontal: 6, vertical: 6)
            .background(.surfaceSunken)
            .cornerRadius(4)
            .border(.divider, width: 1))
        }

        private func moduleParameterSummary(_ module: ParticleEmitterModule) -> String {
            switch module.settings {
            case .emission:
                return L("Spawn rate, bursts, prewarm, and simulation speed")
            case .shape:
                return L("Emitter volume and local spawn offset")
            case .velocity:
                return L("Initial velocity, randomness, and inheritance")
            case .forces:
                return L("Gravity, noise, force fields, and vector fields")
            case .collision:
                return L("Collision surface and response")
            case .appearance:
                return L("Lifetime, size, color, spin, and curves")
            case .textureSheet:
                return L("Atlas playback and frame window")
            case .renderer:
                return L("Draw mode, culling, LOD, bounds, and stretch")
            case .trails:
                return L("Trail cache, ribbon shape, and quality")
            case .subEmitters:
                return L("Event driven child particle rules")
            case .gpuSimulation:
                return L("Simulation backend and dispatch size")
            }
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

        private func moduleBackendStatus(_ module: ParticleEmitterModule) -> ModuleRuntimeStatus {
            guard module.isEnabled else {
                return ModuleRuntimeStatus(text: L("Disabled"), tone: .muted)
            }

            if case let .gpuSimulation(settings) = module.settings {
                if diagnostics.eventReport.droppedReadbackEventCount > 0 {
                    return ModuleRuntimeStatus(text: L("GPU Readback Drop"), tone: .warning)
                }
                if diagnostics.hasGPUSimulationWork {
                    return ModuleRuntimeStatus(text: L("GPU Active"), tone: .success)
                }
                if let plan = diagnostics.selectedGPUSimulationPlan {
                    return gpuPlanStatus(plan)
                }
                switch settings.simulationBackend {
                case .cpu:
                    return ModuleRuntimeStatus(text: L("CPU"), tone: .muted)
                case .gpuIfSupported:
                    return ModuleRuntimeStatus(text: L("GPU Preferred"), tone: .info)
                case .gpuRequired:
                    return ModuleRuntimeStatus(text: L("GPU Required"), tone: .warning)
                }
            }

            if let plan = diagnostics.selectedGPUSimulationPlan {
                switch plan.status {
                case .supported where diagnostics.hasGPUSimulationWork:
                    return ModuleRuntimeStatus(text: L("GPU Sim"), tone: .success)
                case .supported:
                    return ModuleRuntimeStatus(text: L("GPU Ready"), tone: .info)
                case .fallbackToCPU:
                    return ModuleRuntimeStatus(text: L("CPU Fallback"), tone: .warning)
                case .requiredButUnsupported:
                    return ModuleRuntimeStatus(text: L("GPU Blocked"), tone: .warning)
                case .disabled:
                    break
                }
            }

            switch module.settings {
            case .renderer, .textureSheet, .trails:
                return diagnostics.renderStats.gpuParticleRenderInstanceCount > 0
                    ? ModuleRuntimeStatus(text: L("Render GPU"), tone: .success)
                    : ModuleRuntimeStatus(text: L("Render"), tone: .muted)
            case .subEmitters:
                return diagnostics.eventReport.totalReadbackEventCount > 0
                    ? ModuleRuntimeStatus(text: L("GPU Events"), tone: .info)
                    : ModuleRuntimeStatus(text: L("CPU Events"), tone: .muted)
            default:
                return ModuleRuntimeStatus(text: L("CPU Sim"), tone: .muted)
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
            case "negativeVelocityStretch", "invalidVelocityStretch":
                return L("Stretch")
            case "invalidLODRange", "negativeLODDistance", "lodScaleOutOfRange":
                return L("LOD")
            case "negativeMaxRenderDistance", "negativeFadeRange", "fadeRangeExceedsDistance":
                return L("Distance")
            case "negativeRenderBoundsRadius", "invalidRenderBounds":
                return L("Bounds")
            case "negativeTrailSettings", "trailWithoutSamples":
                return L("Trails")
            case "invalidRibbonSmoothing", "negativeRibbonWidth", "negativeRibbonSegment", "negativeRibbonTiling":
                return L("Ribbon")
            case "tailAlphaOutOfRange", "trailEndAlphaOutOfRange":
                return L("Alpha")
            case "negativeTrailEndSize":
                return L("Trail Size")
            default:
                return issue.code
            }
        }

        private func moduleEditor(index: Int, module: ParticleEmitterModule) -> AnyView {
            let isEnabled = module.isEnabled
            switch module.settings {
            case .emission:
                return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    moduleEditorRows([
                        [
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
                            moduleNumber("Speed",
                                         moduleFloatBinding(index, fallback: 1, get: {
                                             if case let .emission(module) = $0 { return module.simulationSpeed }
                                             return nil
                                         }, set: {
                                             if case var .emission(module) = $0 {
                                                 module.simulationSpeed = $1
                                                 $0 = .emission(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 16,
                                         step: 0.05,
                                         enabled: isEnabled),
                        ],
                        [
                            moduleNumber("Duration",
                                         moduleFloatBinding(index, fallback: 0, get: {
                                             if case let .emission(module) = $0 { return module.duration }
                                             return nil
                                         }, set: {
                                             if case var .emission(module) = $0 {
                                                 module.duration = $1
                                                 $0 = .emission(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 600,
                                         step: 0.1,
                                         enabled: isEnabled),
                            moduleNumber("Dist Rate",
                                         moduleFloatBinding(index, fallback: 0, get: {
                                             if case let .emission(module) = $0 { return module.distanceEmissionRate }
                                             return nil
                                         }, set: {
                                             if case var .emission(module) = $0 {
                                                 module.distanceEmissionRate = $1
                                                 $0 = .emission(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 1000,
                                         step: 1,
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
                        ],
                        [
                            moduleNumber("Burst Int",
                                         moduleFloatBinding(index, fallback: 0, get: {
                                             if case let .emission(module) = $0 { return module.burstInterval }
                                             return nil
                                         }, set: {
                                             if case var .emission(module) = $0 {
                                                 module.burstInterval = $1
                                                 $0 = .emission(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 600,
                                         step: 0.05,
                                         enabled: isEnabled),
                            moduleNumber("Prewarm",
                                         moduleFloatBinding(index, fallback: 0, get: {
                                             if case let .emission(module) = $0 { return module.prewarmTime }
                                             return nil
                                         }, set: {
                                             if case var .emission(module) = $0 {
                                                 module.prewarmTime = $1
                                                 $0 = .emission(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 600,
                                         step: 0.1,
                                         enabled: isEnabled),
                            moduleNumber("Pre Step",
                                         moduleFloatBinding(index, fallback: 1.0 / 30.0, get: {
                                             if case let .emission(module) = $0 { return module.prewarmStep }
                                             return nil
                                         }, set: {
                                             if case var .emission(module) = $0 {
                                                 module.prewarmStep = $1
                                                 $0 = .emission(module)
                                             }
                                         }),
                                         min: 1.0 / 240.0,
                                         max: 1,
                                         step: 0.01,
                                         enabled: isEnabled),
                        ],
                        [
                            moduleNumber("Spawn Cap",
                                         moduleIntBinding(index, fallback: 0, get: {
                                             if case let .emission(module) = $0 { return module.maxSpawnedParticlesPerFrame }
                                             return nil
                                         }, set: {
                                             if case var .emission(module) = $0 {
                                                 module.maxSpawnedParticlesPerFrame = $1
                                                 $0 = .emission(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 100_000,
                                         step: 16,
                                         enabled: isEnabled),
                            moduleNumber("Max Rendered",
                                         moduleIntBinding(index, fallback: 0, get: {
                                             if case let .emission(module) = $0 { return module.maxRenderedParticles }
                                             return nil
                                         }, set: {
                                             if case var .emission(module) = $0 {
                                                 module.maxRenderedParticles = $1
                                                 $0 = .emission(module)
                                             }
                                         }),
                                         min: 0,
                                         max: 100_000,
                                         step: 16,
                                         enabled: isEnabled),
                            moduleText("Seed",
                                       moduleUInt64StringBinding(index, fallback: 0x9E3779B9, get: {
                                           if case let .emission(module) = $0 { return module.seed }
                                           return nil
                                       }, set: {
                                           if case var .emission(module) = $0 {
                                               module.seed = $1
                                               $0 = .emission(module)
                                           }
                                       }),
                                       enabled: isEnabled),
                        ],
                    ])
                    moduleCurveEditor("Rate Curve",
                                      moduleValueBinding(index, fallback: .constant(1), get: {
                                          if case let .emission(module) = $0 { return module.emissionRateCurve }
                                          return nil
                                      }, set: {
                                          if case var .emission(module) = $0 {
                                              module.emissionRateCurve = $1
                                              $0 = .emission(module)
                                          }
                                      }),
                                      enabled: isEnabled)
                    moduleCurveEditor("Distance Curve",
                                      moduleValueBinding(index, fallback: .constant(1), get: {
                                          if case let .emission(module) = $0 { return module.distanceEmissionRateCurve }
                                          return nil
                                      }, set: {
                                          if case var .emission(module) = $0 {
                                              module.distanceEmissionRateCurve = $1
                                              $0 = .emission(module)
                                          }
                                      }),
                                      enabled: isEnabled)
                })
            case .shape:
                return shapeModuleEditor(index: index, module: module, isEnabled: isEnabled)
            case .velocity:
                return velocityModuleEditor(index: index, module: module, isEnabled: isEnabled)
            case .forces:
                return forcesModuleEditor(index: index, module: module, isEnabled: isEnabled)
            case .collision:
                return collisionModuleEditor(index: index, module: module, isEnabled: isEnabled)
            case .appearance:
                return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    moduleEditorRows([
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
                    ])
                    moduleColorRow([
                        moduleColorEditor("Start Color",
                                          moduleColorBinding(index, fallback: SIMD4<Float>(1, 1, 1, 1), get: {
                                              if case let .appearance(module) = $0 { return module.startColor }
                                              return nil
                                          }, set: {
                                              if case var .appearance(module) = $0 {
                                                  module.startColor = $1
                                                  $0 = .appearance(module)
                                              }
                                          }),
                                          enabled: isEnabled),
                        moduleColorEditor("End Color",
                                          moduleColorBinding(index, fallback: SIMD4<Float>(1, 1, 1, 0), get: {
                                              if case let .appearance(module) = $0 { return module.endColor }
                                              return nil
                                          }, set: {
                                              if case var .appearance(module) = $0 {
                                                  module.endColor = $1
                                                  $0 = .appearance(module)
                                              }
                                          }),
                                          enabled: isEnabled),
                    ])
                    moduleCurveEditor("Size Curve",
                                      moduleValueBinding(index, fallback: .linear, get: {
                                          if case let .appearance(module) = $0 { return module.sizeCurve }
                                          return nil
                                      }, set: {
                                          if case var .appearance(module) = $0 {
                                              module.sizeCurve = $1
                                              $0 = .appearance(module)
                                          }
                                      }),
                                      enabled: isEnabled)
                    moduleCurveEditor("Color Curve",
                                      moduleValueBinding(index, fallback: .linear, get: {
                                          if case let .appearance(module) = $0 { return module.colorCurve }
                                          return nil
                                      }, set: {
                                          if case var .appearance(module) = $0 {
                                              module.colorCurve = $1
                                              $0 = .appearance(module)
                                          }
                                      }),
                                      enabled: isEnabled)
                })
            case .textureSheet:
                return textureSheetModuleEditor(index: index, module: module, isEnabled: isEnabled)
            case .renderer:
                let status = moduleBackendStatus(module)
                return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    moduleEditorSection("Draw",
                                        detail: L("Render mode, sort, and alignment"),
                                        tone: status.tone,
                                        content: moduleEditorRows([
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
                                                moduleNumber("Priority",
                                                             moduleIntBinding(index, fallback: 0, get: {
                                                                 if case let .renderer(module) = $0 { return module.renderSortPriority }
                                                                 return nil
                                                             }, set: {
                                                                 if case var .renderer(module) = $0 {
                                                                     module.renderSortPriority = $1
                                                                     $0 = .renderer(module)
                                                                 }
                                                             }),
                                                             min: -10_000,
                                                             max: 10_000,
                                                             step: 1,
                                                             enabled: isEnabled),
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
                                        ]))
                    moduleEditorSection("Culling",
                                        detail: L("Distance fade, LOD, and render bounds"),
                                        tone: status.tone,
                                        content: moduleEditorRows([
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
                                        ]))
                    moduleEditorSection("Velocity Stretch",
                                        detail: L("Billboard elongation driven by particle velocity"),
                                        tone: status.tone,
                                        content: moduleEditorRows([
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
                })
            case .trails:
                let status = moduleBackendStatus(module)
                return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    moduleEditorSection("Trail Cache",
                                        detail: L("History length and sampling budget"),
                                        tone: status.tone,
                                        content: moduleEditorRows([
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
                                        ]))
                    moduleEditorSection("Ribbon Shape",
                                        detail: L("Width, taper, and alpha falloff"),
                                        tone: status.tone,
                                        content: moduleEditorRows([
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
                                        ]))
                    moduleEditorSection("Ribbon Quality",
                                        detail: L("Segment clamp, joins, and smoothing"),
                                        tone: status.tone,
                                        content: moduleEditorRows([
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
                })
            case .subEmitters:
                return subEmittersModuleEditor(index: index, module: module, isEnabled: isEnabled)
            case .gpuSimulation:
                let status = moduleBackendStatus(module)
                return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    moduleEditorSection("Backend",
                                        detail: L("Simulation space and GPU/CPU preference"),
                                        tone: status.tone,
                                        content: moduleEditorRows([
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
                                        ]))
                    moduleEditorSection("Dispatch",
                                        detail: L("Thread group size used by the GPU simulator"),
                                        tone: status.tone,
                                        content: moduleEditorRows([
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
                })
            }
        }

        private func shapeModuleEditor(index: Int,
                                       module: ParticleEmitterModule,
                                       isEnabled: Bool) -> AnyView {
            let status = moduleBackendStatus(module)
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                moduleEditorSection("Emitter Volume",
                                    detail: L("Spawn primitive and sphere radius"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Local Offset",
                                    detail: L("Emitter-space spawn offset"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Box Volume",
                                    detail: L("Half extents for box emission"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Cone Volume",
                                    detail: L("Cone radius and height"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
            })
        }

        private func velocityModuleEditor(index: Int,
                                          module: ParticleEmitterModule,
                                          isEnabled: Bool) -> AnyView {
            let status = moduleBackendStatus(module)
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                moduleEditorSection("Initial Velocity",
                                    detail: L("Base launch vector applied at spawn"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Variation",
                                    detail: L("Random velocity spread and inherited motion"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
            })
        }

        private func forcesModuleEditor(index: Int,
                                        module: ParticleEmitterModule,
                                        isEnabled: Bool) -> AnyView {
            let status = moduleBackendStatus(module)
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                moduleEditorSection("Force Sources",
                                    detail: L("Choose analytic force and vector field source"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Gravity",
                                    detail: L("Constant acceleration applied every simulation step"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Noise",
                                    detail: L("Procedural turbulence strength and frequency"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Radial / Vortex",
                                    detail: L("Force magnitude, radius, falloff, and local center"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Vector Field",
                                    detail: L("Field strength, scale, and scroll speed"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
            })
        }

        private func collisionModuleEditor(index: Int,
                                           module: ParticleEmitterModule,
                                           isEnabled: Bool) -> AnyView {
            let status = moduleStatus(module) ?? moduleBackendStatus(module)
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                moduleEditorSection("Surface",
                                    detail: L("Collision mode and plane position"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Response",
                                    detail: L("Bounce and tangent damping"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
            })
        }

        private func textureSheetModuleEditor(index: Int,
                                              module: ParticleEmitterModule,
                                              isEnabled: Bool) -> AnyView {
            let status = moduleStatus(module) ?? moduleBackendStatus(module)
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                moduleEditorSection("Playback",
                                    detail: L("Frame selection mode and playback rate"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Sheet Grid",
                                    detail: L("Texture atlas rows, columns, and frame count"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Frame Window",
                                    detail: L("Start frame and randomized offset"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
            })
        }

        private func subEmittersModuleEditor(index: Int,
                                             module: ParticleEmitterModule,
                                             isEnabled: Bool) -> AnyView {
            let status = moduleStatus(module) ?? moduleBackendStatus(module)
            return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                moduleEditorSection("Legacy Trigger",
                                    detail: L("Single child emitter trigger kept for compatibility"),
                                    tone: status.tone,
                                    content: moduleEditorRows([
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
                                    ]))
                moduleEditorSection("Child Rules",
                                    detail: L("Event driven sub-emitter rule list"),
                                    tone: status.tone,
                                    content: AnyView(InspectorParticleSubEmittersValue(binding: moduleSubEmitterRulesBinding(index))
                                        .opacity(isEnabled ? 1 : 0.66)))
            })
        }

        private func moduleEditorSection(_ title: String,
                                         detail: String,
                                         tone: ModuleRuntimeTone,
                                         content: AnyView) -> AnyView {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 6) {
                    Box(direction: .column, alignItems: .stretch, spacing: 1) {
                        Text(L(title))
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(.onSurface)
                        Text(detail)
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                content
            }
            .padding(horizontal: 6, vertical: 6)
            .background(.surface)
            .cornerRadius(4)
            .border(tone.background.opacity(0.45), width: 1))
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

        private func moduleText(_ label: String,
                                _ value: Binding<String>,
                                enabled: Bool) -> AnyView {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 2) {
                Text(L(label))
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                TextField("", text: value, size: .small, disabled: !enabled, maxLength: 20)
                    .frame(minWidth: 110)
            }
            .flex())
        }

        private func moduleCurveEditor(_ label: String,
                                       _ value: Binding<ParticleCurve>,
                                       enabled: Bool) -> AnyView {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 3) {
                Text(L(label))
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                InspectorParticleCurveValue(binding: value, isEnabled: enabled)
                    .opacity(enabled ? 1 : 0.72)
            }
            .padding(horizontal: 0, vertical: 0))
        }

        private func moduleColorRow(_ fields: [AnyView]) -> AnyView {
            AnyView(Row(alignment: .center, spacing: 8) {
                for field in fields {
                    field
                }
            })
        }

        private func moduleColorEditor(_ label: String,
                                       _ value: Binding<Color>,
                                       enabled: Bool) -> AnyView {
            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 2) {
                Text(L(label))
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                ColorField(color: value,
                           isEnabled: enabled,
                           showAlpha: true,
                           showsInlineValues: false)
                    .frame(height: 26)
                    .clipped()
                    .opacity(enabled ? 1 : 0.72)
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

        private func moduleUInt64StringBinding(_ index: Int,
                                               fallback: UInt64,
                                               get: @escaping (ParticleEmitterModuleSettings) -> UInt64?,
                                               set: @escaping (inout ParticleEmitterModuleSettings, UInt64) -> Void)
            -> Binding<String> {
            Binding(
                get: {
                    guard binding.wrappedValue.modules.indices.contains(index) else { return "\(fallback)" }
                    return "\(get(binding.wrappedValue.modules[index].settings) ?? fallback)"
                },
                set: { next in
                    let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let value = UInt64(trimmed) else { return }
                    var stack = binding.wrappedValue
                    guard stack.modules.indices.contains(index) else { return }
                    set(&stack.modules[index].settings, value)
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

        private func moduleColorBinding(_ index: Int,
                                        fallback: SIMD4<Float>,
                                        get: @escaping (ParticleEmitterModuleSettings) -> SIMD4<Float>?,
                                        set: @escaping (inout ParticleEmitterModuleSettings, SIMD4<Float>) -> Void)
            -> Binding<Color> {
            Binding(
                get: {
                    guard binding.wrappedValue.modules.indices.contains(index) else {
                        return Color(r: fallback.x, g: fallback.y, b: fallback.z, a: fallback.w)
                    }
                    let color = get(binding.wrappedValue.modules[index].settings) ?? fallback
                    return Color(r: color.x, g: color.y, b: color.z, a: color.w)
                },
                set: { next in
                    var stack = binding.wrappedValue
                    guard stack.modules.indices.contains(index) else { return }
                    let color = SIMD4<Float>(clamp01(next.r),
                                             clamp01(next.g),
                                             clamp01(next.b),
                                             clamp01(next.a))
                    set(&stack.modules[index].settings, color)
                    binding.wrappedValue = stack
                }
            )
        }

        private func clamp01(_ value: Float) -> Float {
            max(0, min(1, value))
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
                return "\(fmt(module.emissionRate))/s · speed \(fmt(module.simulationSpeed)) · max \(module.maxParticles)"
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
                return "\(module.renderMode.rawValue) · \(module.sortMode.rawValue) · p\(module.renderSortPriority)"
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
        var isEnabled: Bool = true
        @State private var selectedKeyIndex: Int? = nil

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 7) {
                toolbar
                if case .keyframes(let keyframes) = binding.wrappedValue {
                    ParticleCurvePreview(binding: binding,
                                         selectedKeyIndex: $selectedKeyIndex,
                                         isEnabled: isEnabled)
                        .frame(height: ParticleCurveEditorLayout.previewHeight)
                    ParticleCurveKeyframeRows(binding: binding,
                                              keyframes: keyframes,
                                              selectedKeyIndex: $selectedKeyIndex,
                                              isEnabled: isEnabled)
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
                       isEnabled: isEnabled,
                       width: 170)
                if case .keyframes(let keyframes) = binding.wrappedValue {
                    Button(L("Add"), isEnabled: isEnabled) { appendKeyframe(to: keyframes) }
                        .buttonStyle(.secondary)
                        .frame(width: 52, height: 24)
                    Button(L("Reset"), isEnabled: isEnabled) {
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
        func row(for field: EditorInspectorField, sectionID: String) -> PropertyGridRow {
            PropertyGridRow(id: field.id,
                            label: field.label,
                            rowHeight: field.value.preferredRowHeight(defaultHeight: 28),
                            layout: field.value.preferredRowLayout) {
                fieldView(field.value,
                          identity: "\(entityID.map(String.init) ?? "none")/\(sectionID)/\(field.id)",
                          particleDiagnostics: particleDiagnostics)
            }
        }

        return sections.flatMap { section -> [PropertyGridSection] in
            let startsCollapsed = collapsedIDs.contains(section.id)
            if section.id == "particle-emitter",
               let moduleStackField = section.fields.first(where: { $0.id == Self.particleModuleStackFieldID }) {
                let primaryFields = section.fields.filter(Self.isPrimaryParticleInspectorField)
                let legacyFields = section.fields.filter(Self.isLegacyParticleInspectorField)
                var result = [
                    PropertyGridSection(
                        id: section.id,
                        title: section.title,
                        rows: ([moduleStackField] + primaryFields).map { row(for: $0, sectionID: section.id) },
                        isCollapsible: true,
                        startsCollapsed: startsCollapsed
                    )
                ]
                if !legacyFields.isEmpty {
                    let compatibilityID = "\(section.id)-compatibility"
                    result.append(
                        PropertyGridSection(
                            id: compatibilityID,
                            title: L("Advanced Compatibility"),
                            rows: legacyFields.map { row(for: $0, sectionID: compatibilityID) },
                            isCollapsible: true,
                            startsCollapsed: true
                        )
                    )
                }
                return result
            }

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

    private static let particleModuleStackFieldID = "particle-module-stack"
    private static let primaryParticleInspectorFieldIDs: Set<String> = [
        "particle-texture",
    ]

    private static func isPrimaryParticleInspectorField(_ field: EditorInspectorField) -> Bool {
        primaryParticleInspectorFieldIDs.contains(field.id)
    }

    private static func isLegacyParticleInspectorField(_ field: EditorInspectorField) -> Bool {
        field.id.hasPrefix("particle-")
            && field.id != particleModuleStackFieldID
            && !isPrimaryParticleInspectorField(field)
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
            let stackIssueCounts = Dictionary(
                grouping: stack.validationIssues(),
                by: \.moduleID
            ).mapValues(\.count)
            let listContentHeight = ParticleModuleStackLayout.listContentHeight(
                stack: stack,
                issueCountsByModuleID: stackIssueCounts
            )
            return max(defaultHeight,
                       ParticleModuleStackLayout.propertyGridRowHeight(listContentHeight: listContentHeight))
        case let .json(_, minHeight):
            return max(defaultHeight, minHeight + 34)
        default:
            return nil
        }
    }
}

private enum ParticleModuleStackLayout {
    static let headerHeight: Float = 58
    static let cardPadding: Float = 16
    static let scrollChromeHeight: Float = 2
    static let listPaddingHeight: Float = 12
    static let advancedSeparatorHeight: Float = 28
    static let collapsedModuleRowHeight: Float = 52
    static let moduleEditorRowHeight: Float = 46
    static let moduleParameterChromeHeight: Float = 30
    static let moduleGPUBackendPanelHeight: Float = 90
    static let moduleIssueHeaderHeight: Float = 18
    static let moduleIssueRowHeight: Float = 30
    static let groupSpacing: Float = 4
    static let rowSpacing: Float = 3
    static let minListViewportHeight: Float = 220
    static let maxListViewportHeight: Float = 520
    static let propertyGridFullWidthLabelHeight: Float = 18
    static let propertyGridFullWidthLabelValueSpacing: Float = 6
    static let propertyGridFullWidthVerticalPadding: Float = 12

    static let advancedModuleIDs: Set<String> = [
        "textureSheet",
        "trails",
        "subEmitters",
        "gpuSimulation",
    ]

    static func listViewportHeight(contentHeight: Float) -> Float {
        BoundedScrollView.viewportHeight(contentHeight: contentHeight,
                                         minHeight: minListViewportHeight,
                                         maxHeight: maxListViewportHeight)
    }

    static func rowHeight(listContentHeight: Float) -> Float {
        headerHeight
            + listViewportHeight(contentHeight: listContentHeight)
            + cardPadding
            + scrollChromeHeight
    }

    static func propertyGridRowHeight(listContentHeight: Float) -> Float {
        rowHeight(listContentHeight: listContentHeight)
            + propertyGridFullWidthLabelHeight
            + propertyGridFullWidthLabelValueSpacing
            + propertyGridFullWidthVerticalPadding
    }

    static func listContentHeight(stack: ParticleModuleStack,
                                  issueCountsByModuleID: [String: Int]) -> Float {
        let groupCount: Float = stack.modules.contains { advancedModuleIDs.contains($0.id) } ? 2 : 1
        let expandedEditorHeight = stack.modules.reduce(Float(0)) { total, module in
            guard module.isExpanded else { return total }
            let issueCount = Float(issueCountsByModuleID[module.id] ?? 0)
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
                + moduleParameterChromeHeight
                + particleModuleEditorHeight(module.settings, rowHeight: moduleEditorRowHeight)
                + gpuBackendHeight
                + issueHeight
        }
        let rowSpacingTotal = Float(max(0, stack.modules.count - Int(groupCount))) * rowSpacing
        return listPaddingHeight
            + (groupCount > 1 ? advancedSeparatorHeight : 0)
            + Float(stack.modules.count) * collapsedModuleRowHeight
            + expandedEditorHeight
            + max(0, groupCount - 1) * groupSpacing
            + rowSpacingTotal
    }
}

private func particleModuleEditorHeight(_ settings: ParticleEmitterModuleSettings,
                                        rowHeight: Float) -> Float {
    let sectionHeaderHeight: Float = 28
    let sectionPadding: Float = 12
    let sectionSpacing: Float = 8
    func sectionHeight(rowCount: Int) -> Float {
        sectionHeaderHeight
            + sectionPadding
            + Float(rowCount) * rowHeight
            + Float(max(0, rowCount - 1)) * 5
            + 6
    }

    if case let .emission(module) = settings {
        return 4 * rowHeight
            + 3 * 5
            + 2 * 8
            + particleModuleCurveEditorHeight(module.emissionRateCurve)
            + particleModuleCurveEditorHeight(module.distanceEmissionRateCurve)
    }
    if case let .appearance(module) = settings {
        return 5 * rowHeight
            + 4 * 5
            + 3 * 8
            + rowHeight
            + particleModuleCurveEditorHeight(module.sizeCurve)
            + particleModuleCurveEditorHeight(module.colorCurve)
    }
    if case let .subEmitters(module) = settings {
        let rulesSectionHeight = sectionHeaderHeight
            + sectionPadding
            + ParticleSubEmitterEditorLayout.valueHeight(ruleCount: module.rules.count)
            + 6
        return sectionHeight(rowCount: 2)
            + sectionSpacing
            + rulesSectionHeight
    }
    if case .shape = settings {
        return sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
    }
    if case .velocity = settings {
        return sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
    }
    if case .forces = settings {
        return sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 2)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
    }
    if case .collision = settings {
        return sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
    }
    if case .textureSheet = settings {
        return sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
    }
    if case .renderer = settings {
        return sectionHeight(rowCount: 2)
            + sectionSpacing
            + sectionHeight(rowCount: 2)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
    }
    if case .trails = settings {
        return sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 2)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
    }
    if case .gpuSimulation = settings {
        return sectionHeight(rowCount: 1)
            + sectionSpacing
            + sectionHeight(rowCount: 1)
    }
    return Float(particleModuleEditorRowCount(settings)) * rowHeight
}

private func particleModuleCurveEditorHeight(_ curve: ParticleCurve) -> Float {
    let valueHeight: Float
    if case let .keyframes(keyframes) = curve {
        valueHeight = ParticleCurveEditorLayout.valueHeight(keyframeCount: keyframes.count)
    } else {
        valueHeight = ParticleCurveEditorLayout.linearValueHeight
    }
    return ParticleCurveEditorLayout.propertyGridLabelHeight + 3 + valueHeight
}

private func particleModuleEditorRowCount(_ settings: ParticleEmitterModuleSettings) -> Int {
    switch settings {
    case .emission:
        return 3
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
        let isEnabled: Bool

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
                                           selectedKeyIndex: selectedKeyIndex,
                                           isEnabled: isEnabled)
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
        let isEnabled: Bool

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
                    Button(isEnabled: isEnabled,
                           isSelected: selectedKeyIndex.wrappedValue == index,
                           tooltip: L("Select keyframe"),
                           action: { selectedKeyIndex.wrappedValue = index }) {
                        Text("\(index + 1)")
                    }
                    .buttonStyle(.toggle)
                    .frame(width: 30, height: 22)
                    NumberField(value: keyTimeBinding(index: index),
                                decimals: 2,
                                size: .small,
                                isEnabled: isEnabled,
                                minValue: 0,
                                maxValue: 1,
                                step: 0.01,
                                showsStepper: true)
                    .frame(width: 74)
                    NumberField(value: keyValueBinding(index: index),
                                decimals: 2,
                                size: .small,
                                isEnabled: isEnabled,
                                minValue: -4,
                                maxValue: 4,
                                step: 0.05,
                                showsStepper: true)
                    .frame(width: 74)
                    Button(icon: .resource(UICommonIcons.close),
                           size: 10,
                           isEnabled: isEnabled && keyframes.count > 2,
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
        guard isEnabled,
              case .keyframes(var keys) = binding.wrappedValue,
              keys.indices.contains(index)
        else { return }
        mutate(&keys[index])
        let editedKey = keys[index]
        let sorted = keys.sortedByTimeStable()
        binding.wrappedValue = .keyframes(sorted)
        selectedKeyIndex.wrappedValue = sorted.nearestIndex(to: editedKey)
    }

    private func removeKeyframe(at index: Int) {
        guard isEnabled, keyframes.count > 2, keyframes.indices.contains(index) else { return }
        var next = keyframes
        next.remove(at: index)
        binding.wrappedValue = .keyframes(next.sortedByTimeStable())
        selectedKeyIndex.wrappedValue = next.isEmpty ? nil : min(index, next.count - 1)
    }
}

private struct ParticleCurvePreview: View {
    let binding: Binding<ParticleCurve>
    let selectedKeyIndex: Binding<Int?>
    let isEnabled: Bool

    var body: some View {
        ParticleCurvePreviewHost(binding: binding,
                                 selectedKeyIndex: selectedKeyIndex,
                                 isEnabled: isEnabled)
            .frame(minWidth: 120, minHeight: 44)
    }
}

private struct ParticleCurvePreviewHost: _PrimitiveView {
    let binding: Binding<ParticleCurve>
    let selectedKeyIndex: Binding<Int?>
    let isEnabled: Bool

    private static let activeKeyIndex = "__particle_curve_active_key_index"

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = isEnabled
        return node
    }

    func _updateNode(_ node: Node) {
        let snapshot = self
        node.isHitTestable = isEnabled
        node.cursor = isEnabled ? .pointer : .notAllowed
        node.draw = { list, origin in
            snapshot.render(node: node, origin: origin, list: list)
        }

        guard let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        registry.setPointer(node) { event, phase, _ in
            guard snapshot.isEnabled, event.button == .left else { return .ignored }
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
            guard snapshot.isEnabled,
                  PointerCaptureHolder.current?.target === node,
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
