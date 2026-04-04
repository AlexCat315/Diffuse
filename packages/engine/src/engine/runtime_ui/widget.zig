//! 运行时 UI 控件基础类型 (GR-7)
//!
//! 定义控件 ID、矩形、颜色、控件数据联合体以及帧指针事件。
//! 控件树由 Canvas 拥有（`ArrayList(Widget)`）。

const std = @import("std");

/// 16 位控件唯一 ID（0 = 无效）
pub const WidgetId = u16;
pub const invalid_widget_id: WidgetId = 0;

/// 屏幕矩形（像素或逻辑坐标）
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 100,
    h: f32 = 20,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.w and
            py >= self.y and py <= self.y + self.h;
    }
};

/// RGBA 颜色（0–255）
pub const Color = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,

    pub fn toF32(self: Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.r)) / 255.0,
            @as(f32, @floatFromInt(self.g)) / 255.0,
            @as(f32, @floatFromInt(self.b)) / 255.0,
            @as(f32, @floatFromInt(self.a)) / 255.0,
        };
    }

    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const red = Color{ .r = 220, .g = 50, .b = 50, .a = 255 };
    pub const green = Color{ .r = 50, .g = 200, .b = 50, .a = 255 };
    pub const blue = Color{ .r = 50, .g = 100, .b = 220, .a = 255 };
};

/// 指针（鼠标/触控）事件
pub const PointerEvent = struct {
    /// 事件类型
    kind: EventKind,
    /// 屏幕坐标（像素，左上角原点）
    x: f32,
    y: f32,
    /// 命中的控件 ID（无 = 0）
    target: WidgetId = invalid_widget_id,

    pub const EventKind = enum { down, up, move };
};

/// 控件类型标签
pub const WidgetKind = enum {
    text,
    button,
    image,
    progress_bar,
    panel,
};

/// 文本控件数据
pub const TextData = struct {
    /// 文本内容（指向持久 buffer，由 Canvas 拥有）
    text: []const u8 = "",
    /// 字体大小（逻辑 px，默认 14）
    font_size: f32 = 14.0,
    color: Color = Color.white,
};

/// 按钮控件数据
pub const ButtonData = struct {
    label: []const u8 = "",
    font_size: f32 = 14.0,
    text_color: Color = Color.white,
    bg_color: Color = .{ .r = 70, .g = 130, .b = 200, .a = 220 },
    hover_color: Color = .{ .r = 90, .g = 150, .b = 220, .a = 240 },
    pressed_color: Color = .{ .r = 50, .g = 100, .b = 170, .a = 255 },
    /// 本帧是否被点击（UI 事件处理后清零）
    clicked: bool = false,
    /// 本帧是否被悬停
    hovered: bool = false,
};

/// 图片控件数据（仅颜色占位；实际纹理通过 handle Index 引用，0 = 无）
pub const ImageData = struct {
    tint: Color = Color.white,
    /// 保留：RHI 纹理句柄索引（0 = 纯色矩形）
    texture_index: u32 = 0,
};

/// 进度条控件数据
pub const ProgressBarData = struct {
    /// 进度值 [0, 1]
    value: f32 = 0.5,
    bg_color: Color = .{ .r = 60, .g = 60, .b = 60, .a = 200 },
    fill_color: Color = .{ .r = 80, .g = 180, .b = 80, .a = 230 },
};

/// 面板（纯矩形背景）
pub const PanelData = struct {
    bg_color: Color = .{ .r = 30, .g = 30, .b = 30, .a = 180 },
};

/// 控件数据联合体
pub const WidgetData = union(WidgetKind) {
    text: TextData,
    button: ButtonData,
    image: ImageData,
    progress_bar: ProgressBarData,
    panel: PanelData,
};

/// 单个控件节点
pub const Widget = struct {
    /// 在 Canvas.widgets 中的唯一 ID（由 Canvas 分配）
    id: WidgetId = invalid_widget_id,
    /// 父控件 ID（0 = Canvas 根）
    parent: WidgetId = invalid_widget_id,
    /// 相对于父控件的矩形（Canvas.ScaleMode 决定坐标系）
    rect: Rect = .{},
    /// 是否可见
    visible: bool = true,
    /// 是否阻止点击穿透（true = 消耗指针事件，不继续向下传递）
    blocks_pointer: bool = false,
    /// 控件数据
    data: WidgetData = .{ .panel = .{} },
};
