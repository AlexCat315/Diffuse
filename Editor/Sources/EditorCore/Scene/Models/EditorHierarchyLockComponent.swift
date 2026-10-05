import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

/// Editor-only component so hierarchy locks participate in SceneRuntime
/// snapshots, undo/redo and dirty revision tracking without leaking into game
/// manifests as a runtime feature.
struct EditorHierarchyLockComponent: RuntimeComponent, Sendable, Equatable {}
