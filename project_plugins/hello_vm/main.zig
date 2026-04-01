// Minimal script_vm plugin for Guava Engine.
//
// Exports the three required entry points that the WasmVM looks for:
//   guava_on_init, guava_on_update, guava_on_destroy
//
// When compiled to WASM (via wasm_compiler), the ScriptRuntime can
// load and instantiate this module.

export fn guava_on_init() void {}

export fn guava_on_update() void {}

export fn guava_on_destroy() void {}
