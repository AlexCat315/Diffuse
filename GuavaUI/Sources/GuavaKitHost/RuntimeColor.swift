import GuavaUIRuntime

// `GuavaUIRuntime` the module is shadowed by a same-named enum, so the module
// prefix can't disambiguate its `Color` from GuavaKit's. This file imports only
// GuavaUIRuntime, so `Color` here unambiguously means the runtime one; the alias
// lets the renderer refer to it without the (broken) module qualifier.
public typealias RuntimeColor = Color
