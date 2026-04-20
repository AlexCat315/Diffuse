//! 输入映射系统 (GR-6)
//!
//! 提供从物理按键/鼠标按钮到带名称的"游戏动作"的统一映射，实现：
//!
//! - 运行时查询：`isActionPressed` / `wasActionJustPressed` / `wasActionJustReleased` / `getAxis`
//! - 编辑器配置与重绑定（JSON 序列化至 `assets/input_actions.json`）
//! - 合成轴：正/负方向按键合并为 [-1, 1] float 轴
//!
//! ## 典型用法（脚本侧）
//!
//! ```zig
//! // 在编辑器或启动时注册动作
//! try action_map.registerAction("move_right");
//! try action_map.bindKey("move_right", .d, 1.0);
//! try action_map.bindKey("move_right", .right, 1.0);
//!
//! // 脚本 onUpdate 中查询
//! const moving = ctx.isActionPressed("move_right");
//! const axis = ctx.getAxis("move_horizontal");  // -1..1
//! ```

const std = @import("std");
const input_mod = @import("input.zig");
const Key = input_mod.Key;
const MouseButton = input_mod.MouseButton;
const InputState = input_mod.InputState;

/// 绑定来源类型
pub const BindingKind = enum(u8) {
    key,
    mouse_button,
};

/// 单个物理绑定：按键或鼠标按钮，带轴缩放
pub const ActionBinding = struct {
    kind: BindingKind = .key,
    /// 按键（仅 kind == .key 时有效）
    key: Key = .space,
    /// 鼠标按钮（仅 kind == .mouse_button 时有效）
    mouse_button: MouseButton = .left,
    /// 轴方向与强度，+1.0 正方向，-1.0 负方向
    axis_scale: f32 = 1.0,
};

/// 动作每帧计算状态（由 ActionMap.update 写入）
pub const ActionFrameState = struct {
    /// 当前帧是否被持续按下
    pressed: bool = false,
    /// 本帧刚按下
    just_pressed: bool = false,
    /// 本帧刚释放
    just_released: bool = false,
    /// 合成轴值，范围 [-1, 1]
    axis: f32 = 0.0,
};

/// 单个命名动作条目（拥有 name 内存 + bindings 列表）
const ActionEntry = struct {
    name: []u8,
    bindings: std.ArrayListUnmanaged(ActionBinding) = .empty,
};

/// 输入动作映射表
///
/// 建议在 Application 初始化后、首帧之前注册所有动作和绑定，
/// 然后在主循环中每帧调用 `update(input)` 刷新计算状态，
/// 最后通过 `isActionPressed` / `getAxis` 等查询。
pub const ActionMap = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(ActionEntry) = .empty,
    frame_states: std.StringHashMapUnmanaged(ActionFrameState) = .empty,

    pub fn init(allocator: std.mem.Allocator) ActionMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ActionMap) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.name);
            entry.bindings.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.frame_states.deinit(self.allocator);
    }

    /// 注册一个命名动作（幂等：已存在时忽略）
    pub fn registerAction(self: *ActionMap, name: []const u8) !void {
        if (self.entries.contains(name)) return;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.entries.put(self.allocator, owned_name, .{ .name = owned_name });
        try self.frame_states.put(self.allocator, owned_name, .{});
    }

    /// 为动作添加按键绑定；axis_scale 通常为 +1.0 或 -1.0
    pub fn bindKey(self: *ActionMap, action: []const u8, key: Key, axis_scale: f32) !void {
        const entry = self.entries.getPtr(action) orelse return error.ActionNotFound;
        try entry.bindings.append(self.allocator, .{
            .kind = .key,
            .key = key,
            .axis_scale = axis_scale,
        });
    }

    /// 为动作添加鼠标按钮绑定
    pub fn bindMouseButton(self: *ActionMap, action: []const u8, button: MouseButton, axis_scale: f32) !void {
        const entry = self.entries.getPtr(action) orelse return error.ActionNotFound;
        try entry.bindings.append(self.allocator, .{
            .kind = .mouse_button,
            .mouse_button = button,
            .axis_scale = axis_scale,
        });
    }

    /// 清除一个动作的所有绑定（用于重绑定流程）
    pub fn clearBindings(self: *ActionMap, action: []const u8) void {
        if (self.entries.getPtr(action)) |entry| {
            entry.bindings.clearRetainingCapacity();
        }
    }

    /// 移除一个动作（释放内存）
    pub fn removeAction(self: *ActionMap, action: []const u8) void {
        if (self.entries.fetchRemove(action)) |kv| {
            var entry = kv.value;
            self.allocator.free(entry.name);
            entry.bindings.deinit(self.allocator);
        }
        _ = self.frame_states.remove(action);
    }

    /// 每帧刷新：从 InputState 计算所有动作的 ActionFrameState
    /// 应在脚本更新之前调用
    pub fn update(self: *ActionMap, raw: *const InputState) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const entry = kv.value_ptr;

            var pressed = false;
            var just_pressed = false;
            var just_released = false;
            var axis: f32 = 0.0;

            for (entry.bindings.items) |b| {
                const is_down = switch (b.kind) {
                    .key => raw.isKeyDown(b.key),
                    .mouse_button => raw.isMouseDown(b.mouse_button),
                };
                const was_pressed = switch (b.kind) {
                    .key => raw.wasKeyPressed(b.key),
                    .mouse_button => raw.wasMousePressed(b.mouse_button),
                };
                const was_released = switch (b.kind) {
                    .key => raw.wasKeyReleased(b.key),
                    .mouse_button => raw.wasMouseReleased(b.mouse_button),
                };

                if (is_down) {
                    pressed = true;
                    axis += b.axis_scale;
                }
                if (was_pressed) just_pressed = true;
                if (was_released) just_released = true;
            }

            if (self.frame_states.getPtr(name)) |state| {
                state.pressed = pressed;
                state.just_pressed = just_pressed;
                state.just_released = just_released;
                state.axis = std.math.clamp(axis, -1.0, 1.0);
            }
        }
    }

    // -----------------------------------------------------------------------
    // 查询 API
    // -----------------------------------------------------------------------

    /// 当前帧动作是否被持续按住
    pub fn isPressed(self: *const ActionMap, action: []const u8) bool {
        const s = self.frame_states.get(action) orelse return false;
        return s.pressed;
    }

    /// 当前帧动作是否刚被按下（上升沿）
    pub fn wasJustPressed(self: *const ActionMap, action: []const u8) bool {
        const s = self.frame_states.get(action) orelse return false;
        return s.just_pressed;
    }

    /// 当前帧动作是否刚被释放（下降沿）
    pub fn wasJustReleased(self: *const ActionMap, action: []const u8) bool {
        const s = self.frame_states.get(action) orelse return false;
        return s.just_released;
    }

    /// 当前帧轴值，范围 [-1, 1]；多绑定叠加后钳位
    pub fn getAxis(self: *const ActionMap, action: []const u8) f32 {
        const s = self.frame_states.get(action) orelse return 0.0;
        return s.axis;
    }

    // -----------------------------------------------------------------------
    // JSON 持久化
    // -----------------------------------------------------------------------

    /// 从 JSON 文本加载动作映射（格式见 assets/input_actions.json）
    ///
    /// 已注册动作的绑定会被**追加**，不会清除原有绑定。
    /// 如需完全覆盖，请先 `deinit` + `init` 后再调用。
    pub fn loadFromJson(self: *ActionMap, json_text: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_text, .{});
        defer parsed.deinit();

        const root_obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidJson,
        };

        const actions_val = root_obj.get("actions") orelse return error.MissingActionsKey;
        const actions_arr = switch (actions_val) {
            .array => |a| a,
            else => return error.InvalidJson,
        };

        for (actions_arr.items) |action_val| {
            const action_obj = switch (action_val) {
                .object => |o| o,
                else => continue,
            };

            const name_val = action_obj.get("name") orelse continue;
            const name_str = switch (name_val) {
                .string => |s| s,
                else => continue,
            };

            try self.registerAction(name_str);

            const bindings_val = action_obj.get("bindings") orelse continue;
            const bindings_arr = switch (bindings_val) {
                .array => |a| a,
                else => continue,
            };

            for (bindings_arr.items) |binding_val| {
                const b = switch (binding_val) {
                    .object => |o| o,
                    else => continue,
                };

                const kind_str = if (b.get("kind")) |k| switch (k) {
                    .string => |s| s,
                    else => "key",
                } else "key";

                const axis_scale: f32 = if (b.get("axis_scale")) |s| switch (s) {
                    .float => |f| @floatCast(f),
                    .integer => |i| @floatFromInt(i),
                    else => 1.0,
                } else 1.0;

                if (std.mem.eql(u8, kind_str, "key")) {
                    const key_val = b.get("key") orelse continue;
                    const key_str = switch (key_val) {
                        .string => |s| s,
                        else => continue,
                    };
                    const key = keyFromString(key_str) orelse continue;
                    self.bindKey(name_str, key, axis_scale) catch continue;
                } else if (std.mem.eql(u8, kind_str, "mouse_button")) {
                    const btn_val = b.get("button") orelse continue;
                    const btn_str = switch (btn_val) {
                        .string => |s| s,
                        else => continue,
                    };
                    const btn = mouseButtonFromString(btn_str) orelse continue;
                    self.bindMouseButton(name_str, btn, axis_scale) catch continue;
                }
            }
        }
    }

    /// 将当前映射序列化为 JSON 字节（调用方负责 free）
    pub fn saveToJsonAlloc(self: *const ActionMap, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.writeAll("{\"actions\":[");
        var it = self.entries.iterator();
        var first_action = true;
        while (it.next()) |kv| {
            if (!first_action) try w.writeByte(',');
            first_action = false;
            const entry = kv.value_ptr;

            try w.print("{{\"name\":\"{s}\"", .{entry.name});
            try w.writeAll(",\"bindings\":[");

            for (entry.bindings.items, 0..) |binding, i| {
                if (i > 0) try w.writeByte(',');
                switch (binding.kind) {
                    .key => try w.print("{{\"kind\":\"key\",\"key\":\"{s}\",\"axis_scale\":{d}}}", .{
                        @tagName(binding.key), binding.axis_scale,
                    }),
                    .mouse_button => try w.print("{{\"kind\":\"mouse_button\",\"button\":\"{s}\",\"axis_scale\":{d}}}", .{
                        @tagName(binding.mouse_button), binding.axis_scale,
                    }),
                }
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
        return buf.toOwnedSlice(allocator);
    }
};

// -----------------------------------------------------------------------
// 辅助函数
// -----------------------------------------------------------------------

fn keyFromString(s: []const u8) ?Key {
    inline for (std.meta.fields(Key)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(Key, f.name);
    }
    return null;
}

fn mouseButtonFromString(s: []const u8) ?MouseButton {
    inline for (std.meta.fields(MouseButton)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(MouseButton, f.name);
    }
    return null;
}

// -----------------------------------------------------------------------
// 单元测试
// -----------------------------------------------------------------------

const testing = std.testing;

test "ActionMap register and query" {
    var map = ActionMap.init(testing.allocator);
    defer map.deinit();

    try map.registerAction("jump");
    try map.bindKey("jump", .space, 1.0);

    var input = input_mod.InputState{};
    input.beginFrame();
    input.setKey(.space, true);
    map.update(&input);

    try testing.expect(map.isPressed("jump"));
    try testing.expect(map.wasJustPressed("jump"));
    try testing.expect(!map.wasJustReleased("jump"));
    try testing.expectApproxEqAbs(@as(f32, 1.0), map.getAxis("jump"), 0.001);
}

test "ActionMap axis composite clamp" {
    var map = ActionMap.init(testing.allocator);
    defer map.deinit();

    try map.registerAction("move_x");
    try map.bindKey("move_x", .d, 1.0);
    try map.bindKey("move_x", .a, -1.0);

    {
        var input = input_mod.InputState{};
        input.beginFrame();
        input.setKey(.d, true);
        map.update(&input);
        try testing.expectApproxEqAbs(@as(f32, 1.0), map.getAxis("move_x"), 0.001);
    }
    {
        var input = input_mod.InputState{};
        input.beginFrame();
        input.setKey(.a, true);
        map.update(&input);
        try testing.expectApproxEqAbs(@as(f32, -1.0), map.getAxis("move_x"), 0.001);
    }
    {
        // both pressed → clamp to [-1, 1]
        var input = input_mod.InputState{};
        input.beginFrame();
        input.setKey(.d, true);
        input.setKey(.a, true);
        map.update(&input);
        const axis = map.getAxis("move_x");
        try testing.expect(axis >= -1.0 and axis <= 1.0);
    }
}

test "ActionMap wasJustReleased" {
    var map = ActionMap.init(testing.allocator);
    defer map.deinit();

    try map.registerAction("fire");
    try map.bindKey("fire", .f, 1.0);

    var input = input_mod.InputState{};
    // press
    input.beginFrame();
    input.setKey(.f, true);
    map.update(&input);
    try testing.expect(map.wasJustPressed("fire"));

    // release
    input.beginFrame();
    input.setKey(.f, false);
    map.update(&input);
    try testing.expect(map.wasJustReleased("fire"));
    try testing.expect(!map.isPressed("fire"));
}

test "ActionMap unknown action returns false/0" {
    var map = ActionMap.init(testing.allocator);
    defer map.deinit();

    var input = input_mod.InputState{};
    map.update(&input);

    try testing.expect(!map.isPressed("nonexistent"));
    try testing.expectApproxEqAbs(@as(f32, 0.0), map.getAxis("nonexistent"), 0.001);
}

test "ActionMap JSON round-trip" {
    var map = ActionMap.init(testing.allocator);
    defer map.deinit();

    try map.registerAction("jump");
    try map.bindKey("jump", .space, 1.0);
    try map.registerAction("fire");
    try map.bindMouseButton("fire", .left, 1.0);

    const json = try map.saveToJsonAlloc(testing.allocator);
    defer testing.allocator.free(json);

    var map2 = ActionMap.init(testing.allocator);
    defer map2.deinit();
    try map2.loadFromJson(json);

    try testing.expect(map2.entries.contains("jump"));
    try testing.expect(map2.entries.contains("fire"));
    const jump_entry = map2.entries.getPtr("jump").?;
    try testing.expectEqual(@as(usize, 1), jump_entry.bindings.items.len);
    try testing.expectEqual(Key.space, jump_entry.bindings.items[0].key);
}
