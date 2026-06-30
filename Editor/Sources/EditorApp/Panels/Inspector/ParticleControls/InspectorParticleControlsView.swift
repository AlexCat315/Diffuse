#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

extension InspectorPanel {
    struct InspectorParticleEmissionShapeValue: View {
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

    struct InspectorParticleCollisionModeValue: View {
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

    struct InspectorParticleSimulationSpaceValue: View {
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

    struct InspectorParticleSimulationBackendValue: View {
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

    struct InspectorParticleCurveValue: View {
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

    struct InspectorParticleBlendModeValue: View {
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

    struct InspectorParticleRenderAlignmentValue: View {
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

    struct InspectorParticleRenderModeValue: View {
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

    struct InspectorParticleSortModeValue: View {
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

    struct InspectorParticleTextureSheetPlaybackModeValue: View {
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

    struct InspectorParticleRenderBoundsModeValue: View {
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

    struct InspectorParticleForceModeValue: View {
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

    struct InspectorParticleVectorFieldModeValue: View {
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

    struct InspectorParticleSubEmitterTriggerValue: View {
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

    struct InspectorParticleSubEmittersValue: View {
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

}

enum ParticleCurveEditorLayout {
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

enum ParticleSubEmitterEditorLayout {
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
