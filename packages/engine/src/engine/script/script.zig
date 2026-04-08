const std = @import("std");
const types = @import("./types.zig");
const context = @import("./context.zig");
const runtime = @import("./runtime.zig");
const vm = @import("./zig_backend.zig");
const hot_reload = @import("./hot_reload.zig");
const vm_interface = @import("./vm_interface.zig");
const csharp_toolchain = @import("./csharp_toolchain.zig");
const editor_utility_runtime = @import("./editor_utility_runtime.zig");
const script_resource_mod = @import("../assets/script_resource.zig");
const parameter_reflection = @import("./parameter_reflection.zig");

pub const types_mod = types;
pub const context_mod = context;
pub const runtime_mod = runtime;
pub const vm_mod = vm;
pub const hot_reload_mod = hot_reload;

/// 导出常用类型
pub const Script = types.Script;
pub const ScriptResource = script_resource_mod.ScriptResource;
pub const ScriptInstance = types.ScriptInstance;
pub const ScriptInstanceId = types.ScriptInstanceId;
pub const ScriptInstanceState = types.ScriptInstanceState;
pub const ScriptVTable = types.ScriptVTable;
pub const ScriptLanguage = types.ScriptLanguage;
pub const VmRole = types.VmRole;
pub const ScriptError = types.ScriptError;
pub const ScriptSystemConfig = types.ScriptSystemConfig;

pub const ScriptContext = context.ScriptContext;
pub const EntityId = context.EntityId;

pub const ScriptRuntime = runtime.ScriptRuntime;
pub const ScriptVM = vm_interface.ScriptVM;
pub const ZigVM = vm.ZigVM;
pub const CSharpVM = vm.CSharpVM;
pub const createGameplayVM = vm.createGameplayVM;
pub const createVM = vm.createVM;
pub const csharp_toolchain_mod = csharp_toolchain;
pub const parameter_reflection_mod = parameter_reflection;
pub const EditorUtilityRuntime = editor_utility_runtime.EditorUtilityRuntime;
pub const EditorUtilityStatus = editor_utility_runtime.Status;
pub const freeEditorUtilitySnapshots = editor_utility_runtime.freeSnapshots;

pub const HotReloadManager = hot_reload.HotReloadManager;
pub const FileWatcher = hot_reload.FileWatcher;

const debug_session = @import("./debug_session.zig");
pub const DebugSession = debug_session.DebugSession;
pub const Breakpoint = debug_session.Breakpoint;
pub const WatchVariable = debug_session.WatchVariable;
pub const StepMode = debug_session.StepMode;
pub const InstanceDebugState = debug_session.InstanceDebugState;

pub const dap_adapter = @import("./dap_adapter.zig");
pub const DapAdapter = dap_adapter.DapAdapter;
