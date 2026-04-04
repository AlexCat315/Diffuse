const std = @import("std");
const types = @import("./types.zig");

const log = std.log.scoped(.script_debug);

/// A single breakpoint definition.
pub const Breakpoint = struct {
    id: u32,
    script_handle: u64,
    /// Source line (1-based). Used for display / matching.
    line: u32,
    enabled: bool = true,
    hit_count: u32 = 0,
};

/// Stepping mode for the debugger.
pub const StepMode = enum {
    none,
    step_into,
    step_over,
    @"continue",
};

/// Per-instance debug state.
pub const InstanceDebugState = enum {
    running,
    paused,
    stepping,
};

/// Parameter kind for watch variables.
pub const ParamKind = enum {
    float,
    integer,
    boolean,
};

/// A captured variable from parameter reflection.
pub const WatchVariable = struct {
    name: []const u8,
    kind: ParamKind,
    value_float: f32 = 0,
    value_int: i32 = 0,
    value_bool: bool = false,
};

/// Debug session attached to a script instance.
pub const InstanceSession = struct {
    instance_id: types.ScriptInstanceId,
    script_handle: u64,
    state: InstanceDebugState = .running,
    step_mode: StepMode = .none,
    call_stack_buf: []u8 = &.{},
};

/// The debug session manager — tracks breakpoints and per-instance debug state.
pub const DebugSession = struct {
    allocator: std.mem.Allocator,
    breakpoints: std.ArrayListUnmanaged(Breakpoint) = .empty,
    next_bp_id: u32 = 1,
    sessions: std.AutoHashMapUnmanaged(types.ScriptInstanceId, InstanceSession) = .empty,
    pause_all: bool = false,
    enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator) DebugSession {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DebugSession) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.call_stack_buf.len > 0) {
                self.allocator.free(entry.value_ptr.call_stack_buf);
            }
        }
        self.sessions.deinit(self.allocator);
        self.breakpoints.deinit(self.allocator);
    }

    // ── Breakpoint management ────────────────────────────────────────────

    pub fn addBreakpoint(self: *DebugSession, script_handle: u64, line: u32) !u32 {
        const id = self.next_bp_id;
        self.next_bp_id += 1;
        try self.breakpoints.append(self.allocator, .{
            .id = id,
            .script_handle = script_handle,
            .line = line,
        });
        log.info("breakpoint #{d} added: handle={d} line={d}", .{ id, script_handle, line });
        return id;
    }

    pub fn removeBreakpoint(self: *DebugSession, bp_id: u32) void {
        for (self.breakpoints.items, 0..) |bp, i| {
            if (bp.id == bp_id) {
                _ = self.breakpoints.swapRemove(i);
                log.info("breakpoint #{d} removed", .{bp_id});
                return;
            }
        }
    }

    pub fn toggleBreakpoint(self: *DebugSession, bp_id: u32) void {
        for (self.breakpoints.items) |*bp| {
            if (bp.id == bp_id) {
                bp.enabled = !bp.enabled;
                return;
            }
        }
    }

    pub fn clearAllBreakpoints(self: *DebugSession) void {
        self.breakpoints.clearRetainingCapacity();
    }

    pub fn getBreakpoints(self: *const DebugSession) []const Breakpoint {
        return self.breakpoints.items;
    }

    // ── Session lifecycle ────────────────────────────────────────────────

    pub fn attachInstance(self: *DebugSession, instance_id: types.ScriptInstanceId, script_handle: u64) !void {
        try self.sessions.put(self.allocator, instance_id, .{
            .instance_id = instance_id,
            .script_handle = script_handle,
        });
    }

    pub fn detachInstance(self: *DebugSession, instance_id: types.ScriptInstanceId) void {
        if (self.sessions.fetchRemove(instance_id)) |kv| {
            const session = kv.value;
            if (session.call_stack_buf.len > 0) {
                self.allocator.free(session.call_stack_buf);
            }
        }
    }

    // ── Execution control ────────────────────────────────────────────────

    pub fn pauseAll(self: *DebugSession) void {
        self.pause_all = true;
        var it_pause = self.sessions.iterator();
        while (it_pause.next()) |entry| {
            entry.value_ptr.state = .paused;
            entry.value_ptr.step_mode = .none;
        }
    }

    pub fn resumeAll(self: *DebugSession) void {
        self.pause_all = false;
        var it_resume = self.sessions.iterator();
        while (it_resume.next()) |entry| {
            entry.value_ptr.state = .running;
            entry.value_ptr.step_mode = .@"continue";
        }
    }

    pub fn stepInstance(self: *DebugSession, instance_id: types.ScriptInstanceId, mode: StepMode) void {
        if (self.sessions.getPtr(instance_id)) |session| {
            session.step_mode = mode;
            session.state = .stepping;
        }
    }

    pub fn resumeInstance(self: *DebugSession, instance_id: types.ScriptInstanceId) void {
        if (self.sessions.getPtr(instance_id)) |session| {
            session.state = .running;
            session.step_mode = .@"continue";
        }
    }

    pub fn getSessionState(self: *const DebugSession, instance_id: types.ScriptInstanceId) ?InstanceDebugState {
        if (self.sessions.get(instance_id)) |session| {
            return session.state;
        }
        return null;
    }

    /// Called before each script update tick. Returns true if the instance
    /// should be skipped (paused).
    pub fn shouldSkipUpdate(self: *DebugSession, instance_id: types.ScriptInstanceId, script_handle: u64) bool {
        if (!self.enabled) return false;

        const session = self.sessions.getPtr(instance_id) orelse return false;

        if (session.state == .paused) return true;

        if (self.pause_all) {
            session.state = .paused;
            return true;
        }

        for (self.breakpoints.items) |*bp| {
            if (bp.enabled and bp.script_handle == script_handle) {
                bp.hit_count += 1;
                session.state = .paused;
                log.info("breakpoint #{d} hit (count={d}) on instance {d}", .{ bp.id, bp.hit_count, instance_id });
                return true;
            }
        }

        if (session.step_mode == .step_into) {
            session.state = .paused;
            session.step_mode = .none;
            return true;
        }

        return false;
    }

    /// Capture the call stack for a script instance (stub — not yet implemented for builtin VMs).
    pub fn captureCallStack(self: *DebugSession, instance: *types.ScriptInstance) ![]const u8 {
        _ = instance;
        _ = self;
        return "";
    }

    /// Read reflected parameters as watch variables (stub — not yet implemented for builtin VMs).
    pub fn captureVariables(_: *DebugSession, allocator: std.mem.Allocator, instance: *types.ScriptInstance) ![]WatchVariable {
        _ = instance;
        return allocator.alloc(WatchVariable, 0);
    }

    // ── Query helpers ────────────────────────────────────────────────────

    pub fn isPaused(self: *const DebugSession) bool {
        var it_chk = self.sessions.iterator();
        while (it_chk.next()) |entry| {
            if (entry.value_ptr.state == .paused) return true;
        }
        return false;
    }

    pub fn activeSessionCount(self: *const DebugSession) u32 {
        return @intCast(self.sessions.count());
    }
};

test "DebugSession: init/deinit" {
    var session = DebugSession.init(std.testing.allocator);
    defer session.deinit();
    try std.testing.expectEqual(@as(u32, 0), session.activeSessionCount());
}

test "DebugSession: breakpoint lifecycle" {
    var session = DebugSession.init(std.testing.allocator);
    defer session.deinit();

    const bp1 = try session.addBreakpoint(42, 10);
    const bp2 = try session.addBreakpoint(42, 20);
    try std.testing.expectEqual(@as(usize, 2), session.getBreakpoints().len);

    session.toggleBreakpoint(bp1);
    try std.testing.expect(!session.getBreakpoints()[0].enabled);

    session.removeBreakpoint(bp2);
    try std.testing.expectEqual(@as(usize, 1), session.getBreakpoints().len);

    session.clearAllBreakpoints();
    try std.testing.expectEqual(@as(usize, 0), session.getBreakpoints().len);
}
