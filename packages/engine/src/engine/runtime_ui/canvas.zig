//! 运行时 UI Canvas (GR-7)
//!
//! Canvas 是游戏内 UI 的根容器，负责：
//! 1. 维护控件树（`ArrayList(Widget)`）
//! 2. 分辨率自适应缩放（Scale-to-Fit / Constant-Pixel-Size 两种模式）
//! 3. 指针事件命中检测与点击穿透控制
//! 4. 按钮 clicked / hovered 状态更新
//!
//! ## 生命周期
//!
//! ```zig
//! var canvas = Canvas.init(allocator, .{ .reference_width = 1920, .reference_height = 1080 });
//! defer canvas.deinit();
//!
//! // 添加控件（返回 WidgetId，用于后续查询/更新）
//! const btn_id = try canvas.addWidget(.{
//!     .rect = .{ .x = 100, .y = 100, .w = 200, .h = 50 },
//!     .blocks_pointer = true,
//!     .data = .{ .button = .{ .label = "Start" } },
//! });
//!
//! // 每帧：处理输入事件 → 渲染
//! canvas.processPointerEvent(ptr_event, screen_width, screen_height);
//! // ... 调用 ui_render.render(&canvas, imgui_draw_list, screen_width, screen_height)
//!
//! // 查询按钮状态
//! if (canvas.wasButtonClicked(btn_id)) { ... }
//! ```

const std = @import("std");
const widget_mod = @import("widget.zig");

pub const Widget = widget_mod.Widget;
pub const WidgetId = widget_mod.WidgetId;
pub const WidgetKind = widget_mod.WidgetKind;
pub const WidgetData = widget_mod.WidgetData;
pub const Rect = widget_mod.Rect;
pub const Color = widget_mod.Color;
pub const PointerEvent = widget_mod.PointerEvent;

/// 坐标缩放模式
pub const ScaleMode = enum {
    /// 以 reference 分辨率为基准线性缩放（推荐用于 HUD）
    scale_to_fit,
    /// 始终使用像素坐标（不随分辨率缩放）
    constant_pixel_size,
};

pub const CanvasConfig = struct {
    /// 参考分辨率（scale_to_fit 模式下使用）
    reference_width: f32 = 1920.0,
    reference_height: f32 = 1080.0,
    /// 缩放模式
    scale_mode: ScaleMode = .scale_to_fit,
};

/// 游戏内 UI Canvas
pub const Canvas = struct {
    allocator: std.mem.Allocator,
    config: CanvasConfig,
    /// 控件列表（索引即内部 slot；ID 从 1 开始，0=invalid）
    widgets: std.ArrayListUnmanaged(Widget) = .empty,
    /// 下一个分配的 ID
    next_id: WidgetId = 1,
    /// 字符串内容池（label / text），拥有内存
    string_pool: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: CanvasConfig) Canvas {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Canvas) void {
        for (self.string_pool.items) |s| self.allocator.free(s);
        self.string_pool.deinit(self.allocator);
        self.widgets.deinit(self.allocator);
    }

    // -----------------------------------------------------------------------
    // 控件管理
    // -----------------------------------------------------------------------

    /// 添加控件，返回其唯一 ID
    pub fn addWidget(self: *Canvas, w: Widget) !WidgetId {
        var new_w = w;
        new_w.id = self.next_id;
        self.next_id +|= 1;

        // 深拷贝字符串内容到 pool
        new_w = try self.internStrings(new_w);
        try self.widgets.append(self.allocator, new_w);
        return new_w.id;
    }

    /// 移除控件（线性搜索，适合少量控件场景）
    pub fn removeWidget(self: *Canvas, id: WidgetId) void {
        for (self.widgets.items, 0..) |w, i| {
            if (w.id == id) {
                _ = self.widgets.orderedRemove(i);
                return;
            }
        }
    }

    /// 获取控件指针（可修改数据）；id 不存在则返回 null
    pub fn getWidget(self: *Canvas, id: WidgetId) ?*Widget {
        for (self.widgets.items) |*w| {
            if (w.id == id) return w;
        }
        return null;
    }

    /// 清除所有控件
    pub fn clear(self: *Canvas) void {
        self.widgets.clearRetainingCapacity();
        for (self.string_pool.items) |s| self.allocator.free(s);
        self.string_pool.clearRetainingCapacity();
        self.next_id = 1;
    }

    // -----------------------------------------------------------------------
    // 便捷工厂
    // -----------------------------------------------------------------------

    pub fn addText(self: *Canvas, rect: Rect, text: []const u8, color: Color) !WidgetId {
        return self.addWidget(.{
            .rect = rect,
            .data = .{ .text = .{ .text = text, .color = color } },
        });
    }

    pub fn addButton(self: *Canvas, rect: Rect, label: []const u8) !WidgetId {
        return self.addWidget(.{
            .rect = rect,
            .blocks_pointer = true,
            .data = .{ .button = .{ .label = label } },
        });
    }

    pub fn addProgressBar(self: *Canvas, rect: Rect, value: f32) !WidgetId {
        return self.addWidget(.{
            .rect = rect,
            .blocks_pointer = false,
            .data = .{ .progress_bar = .{ .value = value } },
        });
    }

    pub fn addPanel(self: *Canvas, rect: Rect, color: Color) !WidgetId {
        return self.addWidget(.{
            .rect = rect,
            .blocks_pointer = true,
            .data = .{ .panel = .{ .bg_color = color } },
        });
    }

    pub fn addImage(self: *Canvas, rect: Rect, tint: Color) !WidgetId {
        return self.addWidget(.{
            .rect = rect,
            .data = .{ .image = .{ .tint = tint } },
        });
    }

    // -----------------------------------------------------------------------
    // 数据更新助手
    // -----------------------------------------------------------------------

    /// 更新进度条值
    pub fn setProgress(self: *Canvas, id: WidgetId, value: f32) void {
        const w = self.getWidget(id) orelse return;
        if (w.data == .progress_bar) {
            w.data.progress_bar.value = std.math.clamp(value, 0.0, 1.0);
        }
    }

    /// 更新文本内容
    pub fn setText(self: *Canvas, id: WidgetId, text: []const u8) !void {
        const w = self.getWidget(id) orelse return;
        if (w.data == .text) {
            const owned = try self.allocator.dupe(u8, text);
            errdefer self.allocator.free(owned);
            try self.string_pool.append(self.allocator, owned);
            w.data.text.text = owned;
        }
    }

    /// 设置控件可见性
    pub fn setVisible(self: *Canvas, id: WidgetId, visible: bool) void {
        if (self.getWidget(id)) |w| w.visible = visible;
    }

    // -----------------------------------------------------------------------
    // 指针事件处理
    // -----------------------------------------------------------------------

    /// 每帧在脚本查询前调用，更新 button.clicked / hovered 状态
    ///
    /// - `screen_w` / `screen_h`：当前窗口像素尺寸
    pub fn processPointerEvent(
        self: *Canvas,
        event: PointerEvent,
        screen_w: f32,
        screen_h: f32,
    ) void {
        const scale = self.computeScale(screen_w, screen_h);
        const offset = self.computeOffset(screen_w, screen_h, scale);

        // 每帧先清空 clicked；只有 up 事件时才置位
        for (self.widgets.items) |*w| {
            switch (w.data) {
                .button => |*b| {
                    b.clicked = false;
                    b.hovered = false;
                },
                else => {},
            }
        }

        // 逆序遍历（顶层先命中）
        var i = self.widgets.items.len;
        while (i > 0) {
            i -= 1;
            const w = &self.widgets.items[i];
            if (!w.visible) continue;

            const screen_rect = self.toScreenRect(w.rect, scale, offset);
            if (!screen_rect.contains(event.x, event.y)) continue;

            switch (w.data) {
                .button => |*b| {
                    b.hovered = true;
                    if (event.kind == .up) b.clicked = true;
                },
                else => {},
            }

            if (w.blocks_pointer) break;
        }
    }

    /// 查询按钮本帧是否被点击
    pub fn wasButtonClicked(self: *const Canvas, id: WidgetId) bool {
        for (self.widgets.items) |w| {
            if (w.id != id) continue;
            return switch (w.data) {
                .button => |b| b.clicked,
                else => false,
            };
        }
        return false;
    }

    /// 查询按钮本帧是否被悬停
    pub fn isButtonHovered(self: *const Canvas, id: WidgetId) bool {
        for (self.widgets.items) |w| {
            if (w.id != id) continue;
            return switch (w.data) {
                .button => |b| b.hovered,
                else => false,
            };
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // 坐标系转换
    // -----------------------------------------------------------------------

    /// 将逻辑矩形转换为屏幕像素矩形
    pub fn toScreenRect(self: *const Canvas, r: Rect, scale: f32, offset: [2]f32) Rect {
        return switch (self.config.scale_mode) {
            .scale_to_fit => .{
                .x = r.x * scale + offset[0],
                .y = r.y * scale + offset[1],
                .w = r.w * scale,
                .h = r.h * scale,
            },
            .constant_pixel_size => r,
        };
    }

    /// 计算 scale_to_fit 时的等比缩放系数（最小轴适配）
    pub fn computeScale(self: *const Canvas, screen_w: f32, screen_h: f32) f32 {
        if (self.config.scale_mode == .constant_pixel_size) return 1.0;
        const sx = screen_w / self.config.reference_width;
        const sy = screen_h / self.config.reference_height;
        return @min(sx, sy);
    }

    /// 计算居中偏移（scale_to_fit 模式）
    pub fn computeOffset(self: *const Canvas, screen_w: f32, screen_h: f32, scale: f32) [2]f32 {
        if (self.config.scale_mode == .constant_pixel_size) return .{ 0.0, 0.0 };
        return .{
            (screen_w - self.config.reference_width * scale) * 0.5,
            (screen_h - self.config.reference_height * scale) * 0.5,
        };
    }

    // -----------------------------------------------------------------------
    // 字符串内存管理
    // -----------------------------------------------------------------------

    fn internStrings(self: *Canvas, w: Widget) !Widget {
        var out = w;
        switch (out.data) {
            .text => |*t| {
                if (t.text.len > 0) {
                    const owned = try self.allocator.dupe(u8, t.text);
                    try self.string_pool.append(self.allocator, owned);
                    t.text = owned;
                }
            },
            .button => |*b| {
                if (b.label.len > 0) {
                    const owned = try self.allocator.dupe(u8, b.label);
                    try self.string_pool.append(self.allocator, owned);
                    b.label = owned;
                }
            },
            else => {},
        }
        return out;
    }
};

// -----------------------------------------------------------------------
// 单元测试
// -----------------------------------------------------------------------

const testing = std.testing;

test "Canvas addWidget / getWidget" {
    var canvas = Canvas.init(testing.allocator, .{});
    defer canvas.deinit();

    const id = try canvas.addButton(.{ .x = 10, .y = 10, .w = 100, .h = 40 }, "Play");
    try testing.expect(id != widget_mod.invalid_widget_id);

    const w = canvas.getWidget(id);
    try testing.expect(w != null);
    try testing.expectEqual(WidgetKind.button, std.meta.activeTag(w.?.data));
}

test "Canvas wasButtonClicked on pointer up" {
    var canvas = Canvas.init(testing.allocator, .{
        .scale_mode = .constant_pixel_size,
    });
    defer canvas.deinit();

    const id = try canvas.addButton(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, "OK");

    // pointer down — should set hovered but not clicked
    canvas.processPointerEvent(.{ .kind = .down, .x = 50, .y = 50 }, 1920, 1080);
    try testing.expect(!canvas.wasButtonClicked(id));
    try testing.expect(canvas.isButtonHovered(id));

    // pointer up inside — should set clicked
    canvas.processPointerEvent(.{ .kind = .up, .x = 50, .y = 50 }, 1920, 1080);
    try testing.expect(canvas.wasButtonClicked(id));
}

test "Canvas pointer blocked by upper widget" {
    var canvas = Canvas.init(testing.allocator, .{
        .scale_mode = .constant_pixel_size,
    });
    defer canvas.deinit();

    // Bottom panel — no blocks_pointer
    _ = try canvas.addPanel(.{ .x = 0, .y = 0, .w = 200, .h = 200 }, Color.black);
    // Top button — blocks_pointer = true
    const top_id = try canvas.addButton(.{ .x = 0, .y = 0, .w = 200, .h = 200 }, "Top");

    canvas.processPointerEvent(.{ .kind = .up, .x = 100, .y = 100 }, 1920, 1080);
    try testing.expect(canvas.wasButtonClicked(top_id));
}

test "Canvas setProgress clamps" {
    var canvas = Canvas.init(testing.allocator, .{});
    defer canvas.deinit();

    const id = try canvas.addProgressBar(.{}, 0.5);
    canvas.setProgress(id, 1.5);
    const w = canvas.getWidget(id).?;
    try testing.expectApproxEqAbs(@as(f32, 1.0), w.data.progress_bar.value, 0.001);
}
