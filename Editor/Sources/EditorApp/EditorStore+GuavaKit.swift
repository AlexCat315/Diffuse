// Retroactive conformance: EditorStore already conforms to
// GuavaUIRuntime._ObservableObject; register it for GuavaKit too so
// `@Observed` can subscribe to store changes.
//
// The two protocols share identical requirements (same method names and
// signatures), so no additional implementation is needed.

import GuavaKit
import EditorCore

extension EditorStore: GuavaKit._ObservableObject {}
