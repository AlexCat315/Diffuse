import CapabilityRuntime
import Foundation

/// An async backend that resolves natural-language intents by consulting an
/// external or local AI system.
///
/// Implement this protocol to plug in any AI provider — a commercial LLM API,
/// a locally-trained model, a rule-based remote service, or a test stub.
/// The coordinator calls `resolve` and never depends on a concrete type.
///
/// # Implementing a backend
/// ```swift
/// struct MyModelBackend: IntentResolverBackend {
///     func resolve(_ intent: NaturalLanguageIntent,
///                  context: NaturalLanguageIntentContext,
///                  capabilities: [CapabilitySymbolicView]) async throws -> IntentResolutionResult {
///         // call your model, return an IntentResolutionResult
///     }
/// }
/// ```
public protocol IntentResolverBackend: Sendable {
    func resolve(_ intent: NaturalLanguageIntent,
                 context: NaturalLanguageIntentContext,
                 capabilities: [CapabilitySymbolicView]) async throws -> IntentResolutionResult
}
