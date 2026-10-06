/// Marker protocol for property wrappers managed by the composition system.
///
/// Conforming types (`@State`, `@Binding`) signal to the runtime that
/// the property participates in dependency tracking and recompose scheduling.
public protocol DynamicProperty {}
