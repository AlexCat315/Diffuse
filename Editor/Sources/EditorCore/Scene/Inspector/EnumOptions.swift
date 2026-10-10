import GuavaUIRuntime
import SceneRuntime

/// An engine enum the inspector presents through the shared choices control.
///
/// Conformance belongs to the editor layer: option IDs are only compared inside
/// one presentation, and labels are UI strings the runtime never sees.
public protocol EditorInspectorEnumOption: CaseIterable, Hashable {
    var inspectorOptionID: String { get }
    var inspectorOptionLabel: String { get }
}

public extension EditorInspectorFieldValue {
    /// Presents a typed enum through the shared choices control. An enum field
    /// built this way needs no dedicated case, view, multi-selection merge rule
    /// or row metric of its own.
    static func options<Kind: EditorInspectorEnumOption>(_ binding: Binding<Kind>) -> Self {
        .stringOptions(
            Binding(
                get: { binding.wrappedValue.inspectorOptionID },
                set: { next in
                    guard let kind = Kind.allCases.first(where: { $0.inspectorOptionID == next }) else { return }
                    binding.wrappedValue = kind
                }),
            options: Kind.allCases.map {
                EditorInspectorStringOption(value: $0.inspectorOptionID, label: $0.inspectorOptionLabel)
            })
    }
}
