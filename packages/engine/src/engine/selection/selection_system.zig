const std = @import("std");
const world_mod = @import("../scene/world.zig");
const input_mod = @import("../core/input.zig");

// ─────────────────────────── ECS 组件 ───────────────────────────

/// 可选中单位组件 — 挂载在可被框选/点选的游戏单位上
pub const Selectable = struct {
    team_id: u8 = 0,
    /// 单位类型标识（用于双击选同类型）
    unit_type_id: u32 = 0,
    /// 选中半径（用于点击判断和框选中心点匹配）
    selection_radius: f32 = 0.5,
    /// 当前是否被选中（由 SelectionSystem 维护）
    selected: bool = false,
    enabled: bool = true,
};

/// 选择命令接收器 — 挂载在可接收右键指令的单位上
pub const CommandReceiver = struct {
    team_id: u8 = 0,
    /// 最近收到的命令
    pending_command: Command = .{ .kind = .none },
    enabled: bool = true,
};

/// 指令类型
pub const Command = struct {
    kind: CommandKind = .none,
    /// 目标世界坐标（移动/攻击移动）
    target_position: [3]f32 = .{ 0, 0, 0 },
    /// 目标实体 ID（攻击/跟随具体目标）
    target_entity: ?world_mod.EntityId = null,
};

pub const CommandKind = enum(u8) {
    none = 0,
    move = 1,
    attack_move = 2,
    attack_target = 3,
    patrol = 4,
    stop = 5,
    hold_position = 6,
};

// ─────────────────────────── 系统 ───────────────────────────

/// 编组槽位数量（1‥3 对应键盘 1‥3）
const max_control_groups: usize = 3;
/// 每组最大单位数
const max_group_size: usize = 64;

/// 游戏内单位选择系统（区别于编辑器选择，这是运行时选择）
pub const SelectionSystem = struct {
    allocator: std.mem.Allocator,
    /// 本地玩家队伍 ID
    local_team_id: u8 = 0,

    // ── 框选状态 ──
    drag_start: ?[2]f32 = null,
    is_dragging: bool = false,
    /// 拖拽阈值（像素），超过此值视为框选而非点击
    drag_threshold: f32 = 5.0,

    // ── 编组 ──
    control_groups: [max_control_groups][max_group_size]world_mod.EntityId = undefined,
    control_group_sizes: [max_control_groups]u8 = [_]u8{0} ** max_control_groups,

    // ── 视口参数（需要每帧由外部设置）──
    view_projection: [16]f32 = [_]f32{0} ** 16,
    viewport_width: f32 = 0,
    viewport_height: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) SelectionSystem {
        var sys = SelectionSystem{
            .allocator = allocator,
        };
        // 清零编组
        for (&sys.control_groups) |*group| {
            @memset(group, 0);
        }
        return sys;
    }

    pub fn deinit(self: *SelectionSystem) void {
        _ = self;
    }

    /// 设置当前帧的视口参数（在 update 前调用）
    pub fn setViewport(self: *SelectionSystem, vp: [16]f32, w: f32, h: f32) void {
        self.view_projection = vp;
        self.viewport_width = w;
        self.viewport_height = h;
    }

    /// 每帧更新
    pub fn update(self: *SelectionSystem, world: *world_mod.World, input: *const input_mod.InputState) void {
        const left = @intFromEnum(input_mod.MouseButton.left);
        const right = @intFromEnum(input_mod.MouseButton.right);

        // ── 左键按下：开始拖拽 ──
        if (input.mouse_pressed[left]) {
            self.drag_start = input.mouse_position;
            self.is_dragging = false;
        }

        // ── 左键按住：检测是否构成拖拽 ──
        if (input.mouse_down[left]) {
            if (self.drag_start) |start| {
                const dx = input.mouse_position[0] - start[0];
                const dy = input.mouse_position[1] - start[1];
                if (@abs(dx) > self.drag_threshold or @abs(dy) > self.drag_threshold) {
                    self.is_dragging = true;
                }
            }
        }

        // ── 左键释放 ──
        if (input.mouse_released[left]) {
            if (self.drag_start) |start| {
                if (self.is_dragging) {
                    // 框选
                    self.performBoxSelect(world, start, input.mouse_position, input.modifiers.shift);
                } else if (input.mouse_double_clicked[left]) {
                    // 双击选同类型
                    self.performDoubleClickSelect(world, input.mouse_position);
                } else {
                    // 点击选择
                    self.performClickSelect(world, input.mouse_position, input.modifiers.shift);
                }
            }
            self.drag_start = null;
            self.is_dragging = false;
        }

        // ── 右键：发送指令给已选中单位 ──
        if (input.mouse_pressed[right]) {
            self.issueCommand(world, input.mouse_position, input.modifiers);
        }

        // ── 编组快捷键 ──
        self.handleControlGroups(world, input);
    }

    // ──────── 框选 ────────

    fn performBoxSelect(self: *SelectionSystem, world: *world_mod.World, start: [2]f32, end: [2]f32, additive: bool) void {
        const min_x = @min(start[0], end[0]);
        const min_y = @min(start[1], end[1]);
        const max_x = @max(start[0], end[0]);
        const max_y = @max(start[1], end[1]);

        if (!additive) {
            clearSelection(world);
        }

        for (world.entities.items) |*entity| {
            var sel = entity.unit_selectable orelse continue;
            if (!sel.enabled or sel.team_id != self.local_team_id) continue;
            if (entity.editor_only or entity.is_folder) continue;

            const screen_pos = self.worldToScreen(entity.world_transform_cache.translation) orelse continue;

            if (screen_pos[0] >= min_x and screen_pos[0] <= max_x and
                screen_pos[1] >= min_y and screen_pos[1] <= max_y)
            {
                sel.selected = true;
                entity.unit_selectable = sel;
            }
        }
    }

    // ──────── 点击选择 ────────

    fn performClickSelect(self: *SelectionSystem, world: *world_mod.World, mouse_pos: [2]f32, additive: bool) void {
        var best_entity: ?*world_mod.Entity = null;
        var best_dist: f32 = std.math.inf(f32);

        for (world.entities.items) |*entity| {
            const sel = entity.unit_selectable orelse continue;
            if (!sel.enabled or sel.team_id != self.local_team_id) continue;
            if (entity.editor_only or entity.is_folder) continue;

            const screen_pos = self.worldToScreen(entity.world_transform_cache.translation) orelse continue;
            const dx = screen_pos[0] - mouse_pos[0];
            const dy = screen_pos[1] - mouse_pos[1];
            const dist = @sqrt(dx * dx + dy * dy);

            // 选中半径映射到屏幕空间（简化：固定 30px 容差）
            const click_tolerance: f32 = 30.0;
            if (dist < click_tolerance and dist < best_dist) {
                best_dist = dist;
                best_entity = entity;
            }
        }

        if (!additive) {
            clearSelection(world);
        }

        if (best_entity) |entity| {
            var sel = entity.unit_selectable.?;
            if (additive) {
                sel.selected = !sel.selected; // toggle
            } else {
                sel.selected = true;
            }
            entity.unit_selectable = sel;
        }
    }

    // ──────── 双击选同类型 ────────

    fn performDoubleClickSelect(self: *SelectionSystem, world: *world_mod.World, mouse_pos: [2]f32) void {
        // 先找点击到的单位
        var clicked_type: ?u32 = null;
        var best_dist: f32 = std.math.inf(f32);

        for (world.entities.items) |*entity| {
            const sel = entity.unit_selectable orelse continue;
            if (!sel.enabled or sel.team_id != self.local_team_id) continue;

            const screen_pos = self.worldToScreen(entity.world_transform_cache.translation) orelse continue;
            const dx = screen_pos[0] - mouse_pos[0];
            const dy = screen_pos[1] - mouse_pos[1];
            const dist = @sqrt(dx * dx + dy * dy);

            if (dist < 30.0 and dist < best_dist) {
                best_dist = dist;
                clicked_type = sel.unit_type_id;
            }
        }

        const target_type = clicked_type orelse return;

        // 选中屏幕上所有同类型单位
        clearSelection(world);
        for (world.entities.items) |*entity| {
            var sel = entity.unit_selectable orelse continue;
            if (!sel.enabled or sel.team_id != self.local_team_id) continue;
            if (sel.unit_type_id != target_type) continue;

            // 只选屏幕内可见的
            if (self.worldToScreen(entity.world_transform_cache.translation) != null) {
                sel.selected = true;
                entity.unit_selectable = sel;
            }
        }
    }

    // ──────── 右键指令 ────────

    fn issueCommand(self: *SelectionSystem, world: *world_mod.World, mouse_pos: [2]f32, modifiers: input_mod.Modifiers) void {
        _ = modifiers;
        // 简化：发送移动指令到鼠标位置的地面投射点
        // 实际游戏中需要完整的射线-地面交叉和敌方单位检测
        _ = mouse_pos;

        // 对所有已选中且有 CommandReceiver 的单位发送停止命令（占位逻辑）
        // 完整实现需要 screen→world 射线投射到地面平面
        for (world.entities.items) |*entity| {
            const sel = entity.unit_selectable orelse continue;
            if (!sel.selected) continue;

            if (entity.command_receiver) |*cmd| {
                if (!cmd.enabled) continue;
                // 占位：标记一个 move 命令（目标坐标需要完整射线投射）
                cmd.pending_command = .{
                    .kind = .move,
                    .target_position = .{ 0, 0, 0 },
                    .target_entity = null,
                };
            }
        }

        _ = self;
    }

    // ──────── 编组 ────────

    fn handleControlGroups(self: *SelectionSystem, world: *world_mod.World, input: *const input_mod.InputState) void {
        const group_keys = [_]input_mod.Key{ .one, .two, .three };

        for (group_keys, 0..) |key, group_idx| {
            const key_idx = @intFromEnum(key);
            if (!input.key_pressed[key_idx]) continue;

            if (input.modifiers.ctrl) {
                // Ctrl+N：保存编组
                self.saveControlGroup(world, group_idx);
            } else {
                // N：召回编组
                self.recallControlGroup(world, group_idx);
            }
        }
    }

    fn saveControlGroup(self: *SelectionSystem, world: *world_mod.World, group_idx: usize) void {
        var count: u8 = 0;
        for (world.entities.items) |*entity| {
            const sel = entity.unit_selectable orelse continue;
            if (sel.selected and count < max_group_size) {
                self.control_groups[group_idx][count] = entity.id;
                count += 1;
            }
        }
        self.control_group_sizes[group_idx] = count;
    }

    fn recallControlGroup(self: *SelectionSystem, world: *world_mod.World, group_idx: usize) void {
        clearSelection(world);
        const size = self.control_group_sizes[group_idx];
        var i: u8 = 0;
        while (i < size) : (i += 1) {
            const id = self.control_groups[group_idx][i];
            // 查找实体并选中
            for (world.entities.items) |*entity| {
                if (entity.id == id) {
                    if (entity.unit_selectable) |*sel| {
                        sel.selected = true;
                        entity.unit_selectable = sel.*;
                    }
                    break;
                }
            }
        }
    }

    // ──────── 工具函数 ────────

    fn worldToScreen(self: *const SelectionSystem, pos: [3]f32) ?[2]f32 {
        if (self.viewport_width == 0 or self.viewport_height == 0) return null;

        const vp = self.view_projection;
        const clip_x = vp[0] * pos[0] + vp[4] * pos[1] + vp[8] * pos[2] + vp[12];
        const clip_y = vp[1] * pos[0] + vp[5] * pos[1] + vp[9] * pos[2] + vp[13];
        const clip_w = vp[3] * pos[0] + vp[7] * pos[1] + vp[11] * pos[2] + vp[15];

        if (clip_w <= 0.0) return null;

        const ndc_x = clip_x / clip_w;
        const ndc_y = clip_y / clip_w;
        return .{
            (ndc_x + 1.0) * 0.5 * self.viewport_width,
            (1.0 - ndc_y) * 0.5 * self.viewport_height,
        };
    }

    /// 获取当前选中的实体列表（框选 UI 绘制用）
    pub fn getSelectionBox(self: *const SelectionSystem) ?[4]f32 {
        if (!self.is_dragging) return null;
        const start = self.drag_start orelse return null;
        return .{
            @min(start[0], @as(f32, 0)), // 这里需要当前鼠标位置，但 getSelectionBox 是在渲染时调用
            @min(start[1], @as(f32, 0)),
            0,
            0,
        };
    }

    /// 获取框选矩形（需要当前鼠标位置）
    pub fn getDragRect(self: *const SelectionSystem, current_mouse: [2]f32) ?[4]f32 {
        if (!self.is_dragging) return null;
        const start = self.drag_start orelse return null;
        return .{
            @min(start[0], current_mouse[0]),
            @min(start[1], current_mouse[1]),
            @max(start[0], current_mouse[0]),
            @max(start[1], current_mouse[1]),
        };
    }
};

// ──────── 全局工具 ────────

/// 清除所有选中状态
pub fn clearSelection(world: *world_mod.World) void {
    for (world.entities.items) |*entity| {
        if (entity.unit_selectable) |*sel| {
            sel.selected = false;
            entity.unit_selectable = sel.*;
        }
    }
}

/// 获取所有已选中实体的 ID 列表（调用者负责释放）
pub fn getSelectedIds(world: *const world_mod.World, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(world_mod.EntityId) {
    var result: std.ArrayListUnmanaged(world_mod.EntityId) = .empty;
    for (world.entities.items) |entity| {
        if (entity.unit_selectable) |sel| {
            if (sel.selected) {
                try result.append(allocator, entity.id);
            }
        }
    }
    return result;
}

/// 获取已选中实体数量
pub fn selectedCount(world: *const world_mod.World) usize {
    var count: usize = 0;
    for (world.entities.items) |entity| {
        if (entity.unit_selectable) |sel| {
            if (sel.selected) count += 1;
        }
    }
    return count;
}
