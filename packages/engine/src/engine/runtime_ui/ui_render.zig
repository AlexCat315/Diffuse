//! 运行时 UI 渲染 (GR-7)
//!
//! 通过 ImGui ForegroundDrawList 将 Canvas 控件树渲染到屏幕最顶层，
//! 无需 ImGui 窗口，直接叠加在场景/编辑器内容之上。
//!
//! ## 调用时机
//!
//! 应在 `imgui.newFrame()` 之后、`imgui.render()` 之前调用，例如在编辑器/播放器层的
//! `onUpdate` 末尾：
//!
//! ```zig
//! // editor layer on_update:
//! if (layer_context.playback_controller.shouldAdvance()) {
//!     runtime_ui.render.renderCanvas(&game_canvas,
//!         @floatFromInt(viewport_w), @floatFromInt(viewport_h));
//! }
//! ```

const imgui = @import("../ui/imgui.zig");
const canvas_mod = @import("canvas.zig");
const widget_mod = @import("widget.zig");

const Canvas = canvas_mod.Canvas;
const Widget = widget_mod.Widget;
const WidgetKind = widget_mod.WidgetKind;
const Color = widget_mod.Color;
const Rect = widget_mod.Rect;

/// 将 [0-255] RGBA 颜色转换为 ImGui u32 格式（0xAABBGGRR）
fn colorU32(c: Color) u32 {
    return (@as(u32, c.a) << 24) |
        (@as(u32, c.b) << 16) |
        (@as(u32, c.g) << 8) |
        @as(u32, c.r);
}

/// 渲染整个 Canvas 到屏幕前景
///
/// - `screen_w` / `screen_h`：当前窗口像素尺寸（用于 scale_to_fit 坐标转换）
pub fn renderCanvas(canvas: *const Canvas, screen_w: f32, screen_h: f32) void {
    const dl = imgui.getForegroundDrawList();
    const scale = canvas.computeScale(screen_w, screen_h);
    const offset = canvas.computeOffset(screen_w, screen_h, scale);

    for (canvas.widgets.items) |*w| {
        if (!w.visible) continue;
        const sr = canvas.toScreenRect(w.rect, scale, offset);
        renderWidget(dl, w, sr);
    }
}

fn renderWidget(dl: imgui.ForegroundDrawList, w: *const Widget, sr: Rect) void {
    const p_min = [2]f32{ sr.x, sr.y };
    const p_max = [2]f32{ sr.x + sr.w, sr.y + sr.h };

    switch (w.data) {
        .panel => |d| {
            dl.addRectFilled(p_min, p_max, colorU32(d.bg_color), 0.0);
        },
        .image => |d| {
            dl.addRectFilled(p_min, p_max, colorU32(d.tint), 0.0);
        },
        .text => |d| {
            dl.addText(.{ sr.x, sr.y }, colorU32(d.color), d.text);
        },
        .button => |d| {
            const bg = if (d.clicked)
                d.pressed_color
            else if (d.hovered)
                d.hover_color
            else
                d.bg_color;
            dl.addRectFilled(p_min, p_max, colorU32(bg), 4.0);
            if (d.label.len > 0) {
                // 简单居中：ImGui 默认字体大致 13px，偏移半行高居中
                const text_x = sr.x + sr.w * 0.5 - @as(f32, @floatFromInt(d.label.len)) * 3.5;
                const text_y = sr.y + sr.h * 0.5 - 7.0;
                dl.addText(.{ text_x, text_y }, colorU32(d.text_color), d.label);
            }
        },
        .progress_bar => |d| {
            // 背景
            dl.addRectFilled(p_min, p_max, colorU32(d.bg_color), 2.0);
            // 填充（按 value 裁剪宽度）
            const fill_w = sr.w * @max(0.0, @min(1.0, d.value));
            dl.addRectFilled(
                p_min,
                .{ sr.x + fill_w, sr.y + sr.h },
                colorU32(d.fill_color),
                2.0,
            );
        },
    }
}
