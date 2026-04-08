//! 战争迷雾系统 — CPU 可见性网格 + GPU 渲染叠加
//!
//! ## 架构
//!
//! 1. **可见性网格** (`VisibilityGrid`) — 纯 CPU 端 2D 网格，每帧根据带
//!    `FogVision` 组件的实体位置更新。每个格子有三种状态：
//!    - `unexplored` (0) — 从未见过
//!    - `explored`  (128) — 曾经见过但当前不可见（半透明黑雾）
//!    - `visible`   (255) — 当前可见（完全透明）
//!
//! 2. **GPU 纹理** — 每帧将网格数据上传为 R8 纹理。
//!
//! 3. **叠加渲染** — 全屏 fragment pass 采样该纹理，在场景上叠加迷雾。
//!
//! ## 坐标映射
//!
//! 世界坐标 (X, Z) → 网格坐标 (col, row)：
//!   col = (world_x - origin_x) / cell_size
//!   row = (world_z - origin_z) / cell_size
//!
//! ## 使用方式
//!
//! 1. 在场景中创建一个实体并添加 `FogOfWarConfig` 组件配置全局参数
//! 2. 在需要提供视野的单位上添加 `FogVision` 组件（设置 sight_range）
//! 3. 引擎自动运行 `FogOfWarSystem.update()` 和渲染叠加

const std = @import("std");
const components = @import("../scene/components.zig");
const vec3 = @import("../math/vec3.zig");
const world_mod = @import("../scene/world.zig");

// ── 组件 ────────────────────────────────────────────────

/// 迷雾视野组件 — 挂载在提供视野的实体上
pub const FogVision = struct {
    /// 视野半径（世界单位）
    sight_range: f32 = 12.0,
    /// 所属队伍 ID（0 = 默认本地玩家）
    team_id: u8 = 0,
    /// 是否启用此视野源
    enabled: bool = true,
};

/// 战争迷雾全局配置组件 — 挂载在一个管理用实体上
pub const FogOfWarConfig = struct {
    /// 是否启用迷雾
    enabled: bool = true,
    /// 网格宽度（格数），最大 1024
    grid_width: u16 = 256,
    /// 网格高度（格数），最大 1024
    grid_height: u16 = 256,
    /// 每格对应的世界单位大小
    cell_size: f32 = 2.0,
    /// 网格原点的世界 X 坐标
    origin_x: f32 = -256.0,
    /// 网格原点的世界 Z 坐标
    origin_z: f32 = -256.0,
    /// 本地玩家所属队伍 ID
    local_team_id: u8 = 0,
    /// 未探索区域颜色 (R, G, B, A)
    unexplored_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    /// 已探索但不可见区域颜色
    explored_color: [4]f32 = .{ 0.0, 0.0, 0.0, 0.6 },
};

// ── 可见性网格 ──────────────────────────────────────────

/// 格子状态值
pub const CellState = struct {
    pub const unexplored: u8 = 0;
    pub const explored: u8 = 128;
    pub const visible: u8 = 255;
};

/// CPU 端 2D 可见性网格
pub const VisibilityGrid = struct {
    width: u16,
    height: u16,
    cell_size: f32,
    origin_x: f32,
    origin_z: f32,
    /// 当前帧可见性 — 每帧先清零再根据视野刷新
    current: []u8,
    /// 历史探索状态 — 只增不减，记录所有曾经可见的区域
    explored: []u8,
    /// 最终合成结果 — 上传到 GPU 的数据
    /// 0 = 未探索，128 = 已探索，255 = 当前可见
    composite: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, cell_size: f32, origin_x: f32, origin_z: f32) !VisibilityGrid {
        const size: usize = @as(usize, width) * @as(usize, height);
        const current = try allocator.alloc(u8, size);
        @memset(current, CellState.unexplored);
        const exp = try allocator.alloc(u8, size);
        @memset(exp, CellState.unexplored);
        const comp = try allocator.alloc(u8, size);
        @memset(comp, CellState.unexplored);
        return .{
            .width = width,
            .height = height,
            .cell_size = cell_size,
            .origin_x = origin_x,
            .origin_z = origin_z,
            .current = current,
            .explored = exp,
            .composite = comp,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VisibilityGrid) void {
        self.allocator.free(self.current);
        self.allocator.free(self.explored);
        self.allocator.free(self.composite);
        self.* = undefined;
    }

    /// 每帧开始时清空当前可见性
    pub fn clearCurrent(self: *VisibilityGrid) void {
        @memset(self.current, CellState.unexplored);
    }

    /// 以 (world_x, world_z) 为中心，radius 为半径，标记格子为可见
    pub fn revealCircle(self: *VisibilityGrid, world_x: f32, world_z: f32, radius: f32) void {
        const radius_cells = radius / self.cell_size;
        const center_col = (world_x - self.origin_x) / self.cell_size;
        const center_row = (world_z - self.origin_z) / self.cell_size;

        const min_col = @max(@as(i32, @intFromFloat(@floor(center_col - radius_cells))), 0);
        const max_col = @min(@as(i32, @intFromFloat(@ceil(center_col + radius_cells))), @as(i32, self.width) - 1);
        const min_row = @max(@as(i32, @intFromFloat(@floor(center_row - radius_cells))), 0);
        const max_row = @min(@as(i32, @intFromFloat(@ceil(center_row + radius_cells))), @as(i32, self.height) - 1);

        const r2 = radius_cells * radius_cells;

        var row = min_row;
        while (row <= max_row) : (row += 1) {
            const dy = @as(f32, @floatFromInt(row)) + 0.5 - center_row;
            var col = min_col;
            while (col <= max_col) : (col += 1) {
                const dx = @as(f32, @floatFromInt(col)) + 0.5 - center_col;
                if (dx * dx + dy * dy <= r2) {
                    const idx = @as(usize, @intCast(row)) * @as(usize, self.width) + @as(usize, @intCast(col));
                    self.current[idx] = CellState.visible;
                }
            }
        }
    }

    /// 将当前帧可见性合并到历史探索，并生成合成结果
    pub fn compositePass(self: *VisibilityGrid) void {
        for (self.current, self.explored, self.composite) |cur, *exp, *comp| {
            if (cur == CellState.visible) {
                exp.* = CellState.explored;
                comp.* = CellState.visible;
            } else if (exp.* == CellState.explored) {
                comp.* = CellState.explored;
            } else {
                comp.* = CellState.unexplored;
            }
        }
    }

    /// 重置所有探索状态（例如换队伍时）
    pub fn resetAll(self: *VisibilityGrid) void {
        @memset(self.current, CellState.unexplored);
        @memset(self.explored, CellState.unexplored);
        @memset(self.composite, CellState.unexplored);
    }
};

// ── 系统 ────────────────────────────────────────────────

/// 战争迷雾 ECS 系统
pub const FogOfWarSystem = struct {
    grid: ?VisibilityGrid = null,
    allocator: std.mem.Allocator,
    /// 跟踪配置变化，需要重建网格时触发
    last_width: u16 = 0,
    last_height: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) FogOfWarSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FogOfWarSystem) void {
        if (self.grid) |*g| g.deinit();
        self.* = undefined;
    }

    /// 每帧更新：
    /// 1. 读取场景中的 FogOfWarConfig
    /// 2. 清空当前帧可见性
    /// 3. 遍历所有 FogVision 实体，revealCircle
    /// 4. 合成最终结果
    /// 返回 composite 数据切片供渲染上传（如果迷雾未启用则返回 null）
    pub fn update(self: *FogOfWarSystem, world: *world_mod.World) ?[]const u8 {
        // 查找配置实体
        var config: FogOfWarConfig = .{};
        var found_config = false;
        for (world.entities.items) |*entity| {
            if (entity.fog_of_war_config) |cfg| {
                config = cfg;
                found_config = true;
                break;
            }
        }

        if (!found_config or !config.enabled) {
            return null;
        }

        // 如果网格尺寸变化或未初始化，重建
        if (self.grid == null or self.last_width != config.grid_width or self.last_height != config.grid_height) {
            if (self.grid) |*g| g.deinit();
            self.grid = VisibilityGrid.init(
                self.allocator,
                config.grid_width,
                config.grid_height,
                config.cell_size,
                config.origin_x,
                config.origin_z,
            ) catch return null;
            self.last_width = config.grid_width;
            self.last_height = config.grid_height;
        }

        var grid = &self.grid.?;
        grid.cell_size = config.cell_size;
        grid.origin_x = config.origin_x;
        grid.origin_z = config.origin_z;

        // 清空本帧可见性
        grid.clearCurrent();

        // 遍历所有带 FogVision 的实体
        for (world.entities.items) |*entity| {
            const vision = entity.fog_vision orelse continue;
            if (!vision.enabled) continue;
            if (vision.team_id != config.local_team_id) continue;

            const pos = entity.local_transform.translation;
            grid.revealCircle(pos[0], pos[2], vision.sight_range);
        }

        // 合成
        grid.compositePass();

        return grid.composite;
    }

    /// 获取当前网格尺寸（用于 GPU 纹理创建/上传）
    pub fn gridSize(self: *const FogOfWarSystem) ?struct { width: u16, height: u16 } {
        const g = self.grid orelse return null;
        return .{ .width = g.width, .height = g.height };
    }
};
