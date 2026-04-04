//! 运行时 UI 系统 (GR-7)
//!
//! 提供游戏内 Canvas 体系：分辨率自适应 + 基础控件 + 事件系统 + 脚本 API。
//!
//! ## 模块结构
//!
//! - `canvas.zig`      — Canvas 分辨率缩放与控件树根节点
//! - `widget.zig`      — 基础控件类型（Text / Button / Image / ProgressBar）
//! - `ui_render.zig`   — 通过 ImGui DrawList 将控件树渲染到屏幕
//! - `mod.zig`（本文件）— 公共 re-export

pub const Canvas = @import("canvas.zig").Canvas;
pub const CanvasScaleMode = @import("canvas.zig").ScaleMode;
pub const Widget = @import("widget.zig").Widget;
pub const WidgetId = @import("widget.zig").WidgetId;
pub const WidgetKind = @import("widget.zig").WidgetKind;
pub const PointerEvent = @import("widget.zig").PointerEvent;
pub const Rect = @import("widget.zig").Rect;
pub const Color = @import("widget.zig").Color;
pub const render = @import("ui_render.zig");
