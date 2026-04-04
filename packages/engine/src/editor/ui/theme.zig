//! Centralized theme system for UI components.
//!
//! All color palettes, spacing, and sizing constants live here so that
//! components never hard-code magic numbers.  Swap the palette to restyle
//! the entire editor without touching component code.
//!
//! ## Theme Architecture
//!
//! ```
//! Palette      - Color definitions organized by subsystem
//! Spacing      - 4px grid-based spacing system
//! Typography   - Font sizes and text hierarchy
//! Size         - Icon sizes, control dimensions, panel constraints
//! BorderRadius - Consistent corner rounding
//! ```

const std = @import("std");

// ── Color Types ──────────────────────────────────────────────────────────────

/// RGBA float color used by the UI backend.
pub const Color = [4]f32;

/// Button palette covering the three interactive states.
pub const ButtonPalette = struct {
    bg: Color,
    hovered: Color,
    active: Color,
};

pub const ChipPalette = struct {
    background: Color,
    border: Color,
    text: Color,
};

/// Icon tint in 0-255 byte range (matches RHI texture tinting).
pub const IconTint = [4]u8;

pub const transparent: Color = .{ 0.0, 0.0, 0.0, 0.0 };

// ── Palettes ─────────────────────────────────────────────────────────────────

pub const Palette = struct {
    // ── General Text ─────────────────────────────────────────────────────────
    pub const text_dimmed: Color = .{ 0.55, 0.58, 0.64, 1.0 }; // rgba(0.55, 0.58, 0.64, 1.0) #8C919F
    pub const text_bright: Color = .{ 0.90, 0.91, 0.94, 1.0 }; // rgba(0.90, 0.91, 0.94, 1.0) #E6E8F0
    pub const text_primary: Color = .{ 0.90, 0.91, 0.94, 1.0 }; // rgba(0.90, 0.91, 0.94, 1.0) #E6E8F0
    pub const text_secondary: Color = .{ 0.58, 0.60, 0.66, 1.0 }; // rgba(0.58, 0.60, 0.66, 1.0) #949AA8
    pub const text_muted: Color = .{ 0.38, 0.40, 0.45, 1.0 }; // rgba(0.38, 0.40, 0.45, 1.0) #61646D
    pub const separator: Color = .{ 0.14, 0.15, 0.18, 1.0 }; // rgba(0.14, 0.15, 0.18, 1.0) #24262E

    // ── Background ───────────────────────────────────────────────────────────
    pub const bg = struct {
        pub const dock_area: Color = .{ 0.06, 0.07, 0.09, 1.0 }; // #0F1217 深暗
        pub const panel: Color = .{ 0.09, 0.10, 0.13, 1.0 }; // #171A21 深蓝灰
        pub const panel_border: Color = .{ 0.04, 0.04, 0.06, 1.0 }; // #0A0A0F 近黑
        pub const title_bar: Color = .{ 0.12, 0.13, 0.17, 1.0 }; // #1F212B 深蓝
        pub const menu_bar: Color = .{ 0.08, 0.09, 0.11, 1.0 }; // #14171C 深灰蓝
        pub const header: Color = .{ 0.11, 0.12, 0.15, 1.0 }; // #1C1F26
        pub const child_bg: Color = .{ 0.07, 0.08, 0.10, 1.0 }; // #121419 内嵌更深
        pub const popup_bg: Color = .{ 0.10, 0.11, 0.14, 1.0 }; // #191C24
        pub const modal_bg: Color = .{ 0.03, 0.03, 0.05, 0.88 }; // 深色遮罩
        pub const table_row_alt: Color = .{ 0.08, 0.09, 0.11, 1.0 }; // #14171C
    };

    // ── Interactive ──────────────────────────────────────────────────────────
    pub const interactive = struct {
        pub const button_bg: Color = .{ 0.18, 0.19, 0.23, 1.0 }; // #2E323B
        pub const button_hovered: Color = .{ 0.24, 0.25, 0.30, 1.0 }; // #3D424B
        pub const button_active: Color = .{ 0.28, 0.30, 0.36, 1.0 }; // #474E5A
        pub const button_disabled: Color = .{ 0.15, 0.16, 0.19, 0.50 }; // #262A30 50%
        pub const frame_bg: Color = .{ 0.14, 0.15, 0.18, 1.0 }; // #24262E
        pub const frame_hovered: Color = .{ 0.18, 0.19, 0.23, 1.0 }; // #2E323B
        pub const frame_active: Color = .{ 0.22, 0.23, 0.28, 1.0 }; // #39404A
        pub const accent: Color = .{ 0.30, 0.58, 0.92, 1.0 }; // #4D94EB
        pub const accent_hovered: Color = .{ 0.36, 0.64, 0.96, 1.0 }; // #5CA3F5
        pub const accent_active: Color = .{ 0.24, 0.52, 0.88, 1.0 }; // #3D85E0
    };

    // ── Selection ────────────────────────────────────────────────────────────
    pub const selection = struct {
        pub const bg: Color = .{ 0.25, 0.45, 0.75, 0.30 }; // #3F73BF
        pub const border: Color = .{ 0.30, 0.58, 0.92, 1.0 }; // #4D94EB
        pub const text: Color = .{ 0.92, 0.94, 0.98, 1.0 }; // #EBF0FA 选中时的文本颜色
        pub const hovered: Color = .{ 0.20, 0.30, 0.50, 0.25 }; // #334D80
    };

    // ── Semantic ─────────────────────────────────────────────────────────────
    pub const semantic = struct {
        pub const success: Color = .{ 0.20, 0.70, 0.35, 1.0 }; // #34B252
        pub const success_bg: Color = .{ 0.20, 0.70, 0.35, 0.12 }; // #34B252 12%
        pub const warning: Color = .{ 0.90, 0.68, 0.15, 1.0 }; // #E5AD26
        pub const warning_bg: Color = .{ 0.90, 0.68, 0.15, 0.12 }; // #E5AD26 12%
        pub const err: Color = .{ 0.88, 0.25, 0.22, 1.0 }; // #E14238
        pub const err_bg: Color = .{ 0.88, 0.25, 0.22, 0.12 }; // #E14238 12%
        pub const info: Color = .{ 0.30, 0.58, 0.92, 1.0 }; // #4D94EB
        pub const info_bg: Color = .{ 0.30, 0.58, 0.92, 0.12 }; // #4D94EB 12%
    };

    // ── Hierarchy panel ──────────────────────────────────────────────────────
    pub const hierarchy = struct {
        pub const selected_icon: IconTint = .{ 77, 148, 235, 255 }; // #4D94EB 选中时的图标颜色
        pub const frozen_icon: IconTint = .{ 120, 125, 135, 255 }; // #787D87 冻结时的图标颜色
        pub const active_icon: IconTint = .{ 210, 215, 225, 255 }; // #D2D7E1 可见时的图标颜色
        pub const dimmed_icon: IconTint = .{ 80, 85, 95, 255 }; // #50555F 不可见时的图标颜色

        pub const filter_text: Color = .{ 0.45, 0.48, 0.54, 1.0 }; // #727A87 层级过滤器文本颜色
        pub const row_hovered: Color = .{ 0.16, 0.17, 0.21, 1.0 }; // #282C34 层级行悬停背景
        pub const row_selected: Color = .{ 0.25, 0.45, 0.75, 0.30 }; // #3F73BF 层级行选中背景
        pub const guide_line: Color = .{ 0.18, 0.19, 0.22, 1.0 }; // #2E323B 层级引导线颜色
        pub const drop_target: Color = .{ 0.30, 0.58, 0.92, 0.35 }; // #4D94EB 35% 层级拖放目标高亮
    };

    // ── Status buttons (eye / lock / freeze) ─────────────────────────────────
    pub const status = struct {
        pub const on = ButtonPalette{
            .bg = .{ 0.20, 0.55, 0.85, 0.25 }, // #3390D9 25%
            .hovered = .{ 0.25, 0.60, 0.90, 0.40 }, // #4095E6 40%
            .active = .{ 0.30, 0.65, 0.95, 0.55 }, // #4D94EB 55%
        };
        pub const off = ButtonPalette{
            .bg = .{ 0.45, 0.48, 0.54, 0.10 }, // #727A87 10%
            .hovered = .{ 0.50, 0.52, 0.58, 0.25 }, // #7F858E 25%
            .active = .{ 0.55, 0.58, 0.64, 0.40 }, // #8C919F 40%
        };

        pub const on_icon: IconTint = .{ 77, 148, 235, 255 }; // #4D94EB 亮蓝色图标表示开启状态
        pub const off_icon: IconTint = .{ 120, 125, 135, 255 }; // #787D87 暗灰色图标表示关闭状态
    };

    // ── Toolbar ──────────────────────────────────────────────────────────────
    pub const toolbar = struct {
        pub const idle = ButtonPalette{
            .bg = .{ 0.12, 0.13, 0.16, 0.0 }, // 默认状态下工具栏按钮没有背景色
            .hovered = .{ 0.20, 0.21, 0.26, 0.6 }, // #34373F 60%
            .active = .{ 0.15, 0.16, 0.20, 0.8 }, // #26282D 80%
        };
        pub const active = ButtonPalette{
            .bg = .{ 0.30, 0.58, 0.92, 0.15 }, // #4D94EB 15%
            .hovered = .{ 0.30, 0.58, 0.92, 0.25 }, // #4D94EB 25%
            .active = .{ 0.30, 0.58, 0.92, 0.35 }, // #4D94EB 35%
        };
        pub const accent = ButtonPalette{
            .bg = .{ 0.30, 0.58, 0.92, 0.30 }, // #4D94EB 30%
            .hovered = .{ 0.36, 0.64, 0.96, 0.50 }, // #5CB3F5 50%
            .active = .{ 0.24, 0.52, 0.88, 0.70 }, // #3D85E1 70%
        };
        pub const active_text: Color = .{ 0.35, 0.82, 0.62, 1.0 };
        pub const idle_text: Color = .{ 0.72, 0.76, 0.81, 1.0 };
    };

    pub const layer = struct {
        pub const scrollbar_grab: Color = .{ 0.22, 0.24, 0.28, 1.0 };
        pub const scrollbar_grab_hovered: Color = .{ 0.28, 0.31, 0.36, 1.0 };
        pub const scrollbar_grab_active: Color = .{ 0.34, 0.38, 0.44, 1.0 };
        pub const tab: Color = .{ 0.13, 0.14, 0.17, 1.0 };
        pub const tab_hovered: Color = .{ 0.22, 0.24, 0.30, 1.0 };
        pub const tab_active: Color = .{ 0.18, 0.21, 0.26, 1.0 };
        pub const tab_unfocused: Color = .{ 0.11, 0.12, 0.14, 1.0 };
        pub const tab_unfocused_active: Color = .{ 0.15, 0.17, 0.21, 1.0 };
        pub const resize_grip: Color = transparent;
    };

    // ── Viewport ─────────────────────────────────────────────────────────────
    pub const viewport = struct {
        pub const overlay_bg: Color = .{ 0.10, 0.11, 0.14, 0.40 }; // #191C24 40% 半透明背景用于视口覆盖层
        pub const overlay_border: Color = .{ 0.06, 0.07, 0.09, 0.60 }; // #0F1217 60% 用于视口覆盖层边框
        pub const hud_window_top: Color = .{ 0.42, 0.45, 0.50, 0.26 };
        pub const hud_window_bottom: Color = .{ 0.03, 0.04, 0.05, 0.55 };
        pub const hud_window_side: Color = .{ 0.50, 0.53, 0.58, 0.12 };
        pub const divider: Color = .{ 0.55, 0.59, 0.64, 0.22 };
        pub const grid_line: Color = .{ 0.18, 0.19, 0.22, 0.45 }; // #2E323B 45% 视口网格线颜色
        pub const grid_line_major: Color = .{ 0.26, 0.27, 0.31, 0.55 }; // #42474F 55% 视口主网格线颜色
        pub const gizmo_x: Color = .{ 0.85, 0.20, 0.20, 1.0 }; // #D9534F 红色用于X轴变换工具
        pub const gizmo_y: Color = .{ 0.20, 0.70, 0.30, 1.0 }; // #5CB85C 绿色用于Y轴变换工具
        pub const gizmo_z: Color = .{ 0.25, 0.50, 0.90, 1.0 }; // #5BC0DE 蓝色用于Z轴变换工具
        pub const gizmo_screen: Color = .{ 0.90, 0.85, 0.30, 1.0 }; // #F0AD4E 黄色用于屏幕空间变换工具
        pub const frustum_wire: Color = .{ 0.45, 0.48, 0.54, 0.65 }; // #727A87 65% 用于摄像机视锥线框颜色
        pub const frustum_selected: Color = .{ 0.30, 0.58, 0.92, 0.85 }; // #4D94EB 85% 用于选中对象的摄像机视锥线框颜色
        pub const entity_icon_idle: IconTint = .{ 140, 145, 155, 255 }; // #8C919F 默认状态下的实体图标颜色
        pub const entity_icon_accent: IconTint = .{ 210, 215, 225, 255 }; // #D2D7E1 强调状态下的实体图标颜色（如鼠标悬停）
        pub const entity_icon_selected: IconTint = .{ 77, 148, 235, 255 }; // #4D94EB 选中状态下的实体图标颜色
        pub const cursor_3d: Color = .{ 0.88, 0.90, 0.94, 0.75 }; // #E0E5EE 75% 用于3D光标的颜色
        pub const entity_button_bg: Color = transparent;
        pub const ghost_highlight_text: Color = .{ 0.75, 0.38, 1.0, 1.0 };
    };

    // ── Inspector / Details ──────────────────────────────────────────────────
    pub const inspector = struct {
        pub const ai_preview_badge: Color = .{ 0.72, 0.42, 0.88, 1.0 }; // #B86AF0 用于AI预览的徽章背景颜色
        pub const ai_preview_bg: Color = .{ 0.32, 0.16, 0.50, 0.25 }; // #521A80 25% 用于AI预览的背景颜色
        pub const ai_preview_name: Color = .{ 0.72, 0.42, 0.88, 0.75 }; // #B86AF0 75% 用于AI预览名称文本颜色
        pub const component_header_bg: Color = .{ 0.11, 0.12, 0.15, 1.0 }; // #1C1F26 组件标题背景颜色
        pub const component_header_hovered: Color = .{ 0.16, 0.17, 0.21, 1.0 }; // #282C34 组件标题悬停背景颜色
        pub const property_label: Color = .{ 0.52, 0.54, 0.60, 1.0 }; // #848A97 用于属性标签的文本颜色
        pub const property_value_bg: Color = .{ 0.12, 0.13, 0.16, 1.0 }; // #1F212B 用于属性值输入框的背景颜色
        pub const add_component_bg: Color = .{ 0.10, 0.11, 0.14, 1.0 }; // #191C24 用于“添加组件”按钮的背景颜色
        pub const add_component_hovered: Color = .{ 0.16, 0.17, 0.21, 1.0 }; // #282C34 用于“添加组件”按钮的悬停背景颜色
    };

    // ── Axis colors (transform gizmo / inspector) ────────────────────────────
    pub const axis = struct {
        pub const x_bg: Color = .{ 0.85, 0.20, 0.20, 1.0 }; // #D9534F X轴背景颜色
        pub const y_bg: Color = .{ 0.20, 0.70, 0.30, 1.0 }; // #5CB85C Y轴背景颜色
        pub const z_bg: Color = .{ 0.25, 0.50, 0.90, 1.0 }; // #5BC0DE Z轴背景颜色
        pub const label: Color = .{ 1.0, 1.0, 1.0, 1.0 }; // #FFFFFF 轴标签颜色
    };

    // ── Freeze toggle (legacy text-based button) ─────────────────────────────
    pub const freeze = struct {
        pub const text_active: Color = .{ 0.30, 0.70, 0.95, 1.0 }; // #4D94EB 亮蓝色文本表示冻结状态
        pub const text_inactive: Color = .{ 0.45, 0.48, 0.54, 1.0 }; // #727A87 暗灰色文本表示非冻结状态
        pub const bg_active = ButtonPalette{
            .bg = .{ 0.15, 0.40, 0.70, 0.75 }, // #264D80 75%
            .hovered = .{ 0.20, 0.50, 0.80, 0.85 }, // #3373BF 85%
            .active = .{ 0.10, 0.35, 0.65, 0.90 }, // #1A4065 90%
        };
        pub const bg_inactive = ButtonPalette{
            .bg = .{ 0.14, 0.15, 0.18, 0.50 }, // #24262E 50%
            .hovered = .{ 0.18, 0.19, 0.23, 0.70 }, // #2E323B 70%
            .active = .{ 0.16, 0.17, 0.21, 0.82 }, // #282C34 82%
        };
    };

    // ── Console / Log ────────────────────────────────────────────────────────
    pub const console = struct {
        pub const error_text: Color = .{ 0.88, 0.25, 0.22, 1.0 }; // #E14238 红色用于错误日志文本
        pub const warning_text: Color = .{ 0.90, 0.68, 0.15, 1.0 }; // #E5AD26 黄色用于警告日志文本
        pub const info_text: Color = .{ 0.30, 0.58, 0.92, 1.0 }; // #4D94EB 蓝色用于信息日志文本
        pub const debug_text: Color = .{ 0.42, 0.44, 0.50, 1.0 }; // #6B707F 灰蓝色用于调试日志文本
        pub const row_error: Color = .{ 0.88, 0.25, 0.22, 0.06 }; // #E14238 6% 用于错误日志行背景
        pub const row_warning: Color = .{ 0.90, 0.68, 0.15, 0.06 }; // #E5AD26 6% 用于警告日志行背景
    };

    // ── Content Browser ──────────────────────────────────────────────────────
    pub const content_browser = struct {
        pub const folder_icon: IconTint = .{ 210, 180, 80, 255 }; // #D2B450 文件夹图标颜色
        pub const file_icon: IconTint = .{ 140, 145, 155, 255 }; // #8C919B 文件图标颜色
        pub const thumbnail_bg: Color = .{ 0.08, 0.09, 0.11, 1.0 }; // #14161C 缩略图背景颜色
        pub const thumbnail_border: Color = .{ 0.16, 0.17, 0.20, 1.0 }; // #292C33 缩略图边框颜色
        pub const thumbnail_selected_border: Color = .{ 0.30, 0.58, 0.92, 1.0 }; // #4D94EB 选中缩略图边框颜色
        pub const path_bar_bg: Color = .{ 0.11, 0.12, 0.15, 1.0 }; // #1C1F26 路径栏背景颜色
        pub const drawer_child_bg: Color = .{ 0.10, 0.11, 0.13, 0.96 };
        pub const drawer_bg: Color = .{ 0.06, 0.07, 0.09, 0.96 };
        pub const drawer_header_bg: Color = .{ 0.11, 0.12, 0.15, 0.98 };
        pub const drawer_header_highlight: Color = .{ 0.62, 0.67, 0.74, 0.16 };
        pub const drawer_separator: Color = .{ 0.34, 0.37, 0.42, 0.45 };
        pub const drawer_resize_grip: Color = .{ 0.72, 0.76, 0.82, 0.28 };
        pub const drawer_assistant_body_text: Color = .{ 0.55, 0.60, 0.68, 1.0 };
        pub const drawer_workspace_title_text: Color = .{ 0.78, 0.82, 0.88, 1.0 };
        pub const drawer_empty_text: Color = .{ 0.61, 0.64, 0.68, 1.0 };
        pub const breadcrumb_separator_text: Color = .{ 0.58, 0.62, 0.68, 1.0 };
        pub const bottom_tab = ButtonPalette{
            .bg = transparent,
            .hovered = .{ 0.22, 0.25, 0.29, 0.92 },
            .active = .{ 0.15, 0.18, 0.21, 1.0 },
        };
    };

    // ── AI / Jarvis ──────────────────────────────────────────────────────────
    pub const ai = struct {
        pub const accent: Color = .{ 0.60, 0.34, 0.90, 1.0 }; // #9955E6 AI 高亮颜色
        pub const accent_hovered: Color = .{ 0.66, 0.42, 0.95, 1.0 }; // #A96BF2 AI 高亮悬停颜色
        pub const badge_bg: Color = .{ 0.32, 0.16, 0.50, 0.25 }; // #522880 25% AI 徽章背景颜色
        pub const user_msg_bg: Color = .{ 0.16, 0.17, 0.21, 1.0 }; // #282C34 用户消息背景颜色
        pub const assistant_msg_bg: Color = .{ 0.12, 0.13, 0.16, 1.0 }; // #1F212B 助手消息背景颜色
        pub const streaming_indicator: Color = .{ 0.60, 0.34, 0.90, 1.0 }; // #9955E6 流媒体指示器颜色
    };

    pub const settings = struct {
        pub const section_hover_bg: Color = .{ 1.0, 1.0, 1.0, 0.04 };
        pub const section_arrow_text: Color = .{ 0.60, 0.63, 0.68, 1.0 };
        pub const section_title_text: Color = .{ 0.88, 0.91, 0.95, 1.0 };
        pub const category_selected_bg: Color = .{ 0.17, 0.33, 0.50, 0.72 };
        pub const category_hover_bg: Color = .{ 1.0, 1.0, 1.0, 0.06 };
        pub const category_selected_text: Color = .{ 0.94, 0.97, 1.0, 1.0 };
        pub const category_hover_text: Color = .{ 0.88, 0.91, 0.95, 1.0 };
        pub const category_idle_text: Color = .{ 0.72, 0.76, 0.82, 1.0 };
        pub const choice_active = ButtonPalette{
            .bg = .{ 0.13, 0.45, 0.28, 0.82 },
            .hovered = .{ 0.18, 0.55, 0.35, 0.92 },
            .active = .{ 0.10, 0.35, 0.22, 0.96 },
        };
        pub const choice_idle = ButtonPalette{
            .bg = .{ 0.16, 0.17, 0.19, 0.54 },
            .hovered = .{ 0.21, 0.23, 0.27, 0.74 },
            .active = .{ 0.18, 0.20, 0.24, 0.86 },
        };
        pub const warning_text: Color = .{ 0.95, 0.82, 0.35, 1.0 };
        pub const error_text: Color = .{ 1.0, 0.42, 0.42, 1.0 };
        pub const search_bg: Color = .{ 0.12, 0.13, 0.15, 0.65 };
        pub const sidebar_bg: Color = .{ 0.08, 0.09, 0.10, 0.70 };
        pub const separator: Color = .{ 1.0, 1.0, 1.0, 0.08 };
    };

    pub const timeline = struct {
        pub const summary_text: Color = .{ 0.55, 0.60, 0.68, 1.0 };
        pub const preview_text: Color = .{ 0.80, 0.95, 1.0, 1.0 };
        pub const hint_text: Color = .{ 0.50, 0.52, 0.56, 1.0 };
        pub const empty_text: Color = .{ 0.40, 0.42, 0.46, 1.0 };
        pub const connector_text: Color = .{ 0.35, 0.38, 0.44, 1.0 };
        pub const current_text: Color = .{ 0.98, 0.98, 0.78, 1.0 };
        pub const preview_node_text: Color = .{ 0.80, 0.95, 1.0, 1.0 };
        pub const confirm_button = ButtonPalette{
            .bg = .{ 0.13, 0.50, 0.36, 0.90 },
            .hovered = .{ 0.15, 0.62, 0.43, 1.0 },
            .active = .{ 0.10, 0.40, 0.28, 1.0 },
        };
        pub const human_node = ButtonPalette{
            .bg = .{ 0.16, 0.34, 0.66, 0.88 },
            .hovered = .{ 0.20, 0.41, 0.77, 0.96 },
            .active = .{ 0.13, 0.28, 0.54, 1.0 },
        };
        pub const ai_node = ButtonPalette{
            .bg = .{ 0.47, 0.28, 0.72, 0.88 },
            .hovered = .{ 0.56, 0.33, 0.84, 0.96 },
            .active = .{ 0.38, 0.22, 0.60, 1.0 },
        };
    };

    pub const place_actor = struct {
        pub const card_idle = ButtonPalette{
            .bg = .{ 0.16, 0.17, 0.18, 0.64 },
            .hovered = .{ 0.20, 0.21, 0.22, 0.82 },
            .active = .{ 0.14, 0.15, 0.16, 0.92 },
        };
        pub const card_active = ButtonPalette{
            .bg = .{ 0.16, 0.59, 0.44, 0.8 },
            .hovered = .{ 0.20, 0.69, 0.52, 0.9 },
            .active = .{ 0.12, 0.49, 0.36, 1.0 },
        };
        pub const card_text_muted: Color = .{ 0.55, 0.58, 0.62, 1.0 };
    };

    pub const ai_chat = struct {
        pub const role_user_accent: Color = .{ 0.42, 0.66, 0.95, 1.0 };
        pub const role_assistant_accent: Color = .{ 0.27, 0.86, 0.57, 1.0 };
        pub const role_reasoning_accent: Color = .{ 0.88, 0.76, 0.42, 1.0 };
        pub const role_system_accent: Color = .{ 0.58, 0.62, 0.68, 1.0 };
        pub const user_card_bg: Color = .{ 0.08, 0.13, 0.19, 0.92 };
        pub const assistant_card_bg: Color = .{ 0.08, 0.15, 0.11, 0.92 };
        pub const system_card_bg: Color = .{ 0.12, 0.12, 0.14, 0.92 };
        pub const reasoning_card_bg: Color = .{ 0.10, 0.10, 0.11, 0.92 };
        pub const user_body_text: Color = .{ 0.90, 0.95, 1.0, 1.0 };
        pub const assistant_body_text: Color = .{ 0.88, 0.97, 0.91, 1.0 };
        pub const system_body_text: Color = .{ 0.78, 0.80, 0.84, 1.0 };
        pub const reasoning_body_text: Color = .{ 0.80, 0.80, 0.80, 1.0 };
        pub const message_card_border: Color = .{ 0.18, 0.22, 0.28, 0.95 };
        pub const empty_text: Color = .{ 0.44, 0.47, 0.53, 1.0 };
        pub const status_ready = ChipPalette{
            .background = .{ 0.10, 0.18, 0.15, 1.0 },
            .border = .{ 0.27, 0.58, 0.46, 1.0 },
            .text = .{ 0.78, 0.94, 0.86, 1.0 },
        };
        pub const status_error = ChipPalette{
            .background = .{ 0.22, 0.11, 0.12, 1.0 },
            .border = .{ 0.72, 0.28, 0.31, 1.0 },
            .text = .{ 0.97, 0.79, 0.80, 1.0 },
        };
        pub const status_warning = ChipPalette{
            .background = .{ 0.24, 0.18, 0.08, 1.0 },
            .border = .{ 0.82, 0.63, 0.24, 1.0 },
            .text = .{ 0.98, 0.90, 0.66, 1.0 },
        };
        pub const status_neutral = ChipPalette{
            .background = .{ 0.14, 0.17, 0.22, 1.0 },
            .border = .{ 0.36, 0.42, 0.53, 1.0 },
            .text = .{ 0.77, 0.82, 0.90, 1.0 },
        };
        pub const status_waiting = ChipPalette{
            .background = .{ 0.28, 0.16, 0.08, 1.0 },
            .border = .{ 0.92, 0.46, 0.18, 1.0 },
            .text = .{ 0.99, 0.84, 0.67, 1.0 },
        };
        pub const status_dot_ready: Color = .{ 0.44, 0.86, 0.60, 1.0 };
        pub const status_dot_error: Color = .{ 0.90, 0.38, 0.35, 1.0 };
        pub const status_dot_warning: Color = .{ 0.95, 0.80, 0.30, 1.0 };
        pub const card_border: Color = .{ 0.18, 0.22, 0.28, 0.98 };
        pub const messages_border: Color = .{ 0.17, 0.21, 0.28, 0.98 };
        pub const composer_border: Color = .{ 0.20, 0.28, 0.34, 1.0 };
        pub const setup_card_border: Color = .{ 0.23, 0.42, 0.38, 0.92 };
        pub const setup_title: Color = .{ 0.95, 0.84, 0.44, 1.0 };
        pub const setup_body: Color = .{ 0.80, 0.85, 0.92, 1.0 };
        pub const setup_hint: Color = .{ 0.58, 0.66, 0.76, 1.0 };
        pub const provider_error_text: Color = .{ 0.66, 0.74, 0.84, 1.0 };
        pub const staged_banner_text: Color = .{ 0.98, 0.85, 0.40, 1.0 };
        pub const staged_banner_hint: Color = .{ 0.68, 0.72, 0.80, 1.0 };
        pub const stage_detail_text: Color = .{ 0.58, 0.65, 0.75, 1.0 };
        pub const settings_title: Color = .{ 0.90, 0.93, 0.98, 1.0 };
        pub const settings_description: Color = .{ 0.55, 0.60, 0.68, 1.0 };
        pub const input_hint_text: Color = .{ 0.52, 0.57, 0.66, 1.0 };
        pub const critical_text: Color = .{ 0.90, 0.30, 0.30, 1.0 };
        pub const primary_button = ButtonPalette{
            .bg = .{ 0.13, 0.50, 0.36, 0.88 },
            .hovered = .{ 0.15, 0.62, 0.43, 1.0 },
            .active = .{ 0.10, 0.40, 0.28, 1.0 },
        };
        pub const primary_button_strong = ButtonPalette{
            .bg = .{ 0.13, 0.50, 0.36, 0.90 },
            .hovered = .{ 0.15, 0.62, 0.43, 1.0 },
            .active = .{ 0.10, 0.40, 0.28, 1.0 },
        };
        pub const secondary_button = ButtonPalette{
            .bg = .{ 0.22, 0.24, 0.27, 1.0 },
            .hovered = .{ 0.30, 0.33, 0.37, 1.0 },
            .active = .{ 0.18, 0.20, 0.24, 1.0 },
        };
        pub const secondary_header_button = ButtonPalette{
            .bg = .{ 0.19, 0.22, 0.28, 1.0 },
            .hovered = .{ 0.25, 0.29, 0.36, 1.0 },
            .active = .{ 0.15, 0.18, 0.24, 1.0 },
        };
        pub const dropdown_button = ButtonPalette{
            .bg = .{ 0.12, 0.15, 0.19, 1.0 },
            .hovered = .{ 0.15, 0.19, 0.24, 1.0 },
            .active = .{ 0.18, 0.22, 0.29, 1.0 },
        };
        pub const provider_action_disabled = ButtonPalette{
            .bg = .{ 0.16, 0.18, 0.21, 0.38 },
            .hovered = .{ 0.16, 0.18, 0.21, 0.38 },
            .active = .{ 0.16, 0.18, 0.21, 0.38 },
        };
        pub const provider_action_enabled = ButtonPalette{
            .bg = .{ 0.22, 0.24, 0.27, 1.0 },
            .hovered = .{ 0.30, 0.33, 0.37, 1.0 },
            .active = .{ 0.30, 0.33, 0.37, 1.0 },
        };
        pub const input_frame_bg: Color = .{ 0.07, 0.09, 0.13, 1.0 };
        pub const input_frame_hovered: Color = .{ 0.10, 0.13, 0.18, 1.0 };
        pub const input_frame_active: Color = .{ 0.13, 0.17, 0.24, 1.0 };
        pub const input_border: Color = .{ 0.22, 0.44, 0.38, 0.90 };
        pub const input_text: Color = .{ 0.94, 0.96, 0.99, 1.0 };
        pub const input_text_cursor: Color = .{ 0.24, 0.92, 0.56, 1.0 };
        pub const input_nav_cursor: Color = .{ 0.30, 0.88, 0.67, 1.0 };
        pub const input_text_selected_bg: Color = .{ 0.22, 0.72, 0.56, 0.45 };
    };
};

// ── Spacing ──────────────────────────────────────────────────────────────────
/// 4px grid-based spacing system for consistent layout.
///
/// All spacing values are multiples of 4 for visual consistency.
pub const Spacing = struct {
    // ── Base grid ────────────────────────────────────────────────────────────
    pub const x1: f32 = 4.0;
    pub const x2: f32 = 8.0;
    pub const x3: f32 = 12.0;
    pub const x4: f32 = 16.0;
    pub const x5: f32 = 20.0;
    pub const x6: f32 = 24.0;
    pub const x8: f32 = 32.0;

    // ── Panel internals ──────────────────────────────────────────────────────
    pub const panel_padding: f32 = 6.0;
    pub const panel_spacing: f32 = 4.0;
    pub const section_padding: f32 = 14.0;
    pub const item_spacing: f32 = 10.0;
    pub const row_spacing: f32 = 8.0;
    pub const cell_padding: f32 = 4.0;

    // ── Component spacing ────────────────────────────────────────────────────
    pub const button_padding: [2]f32 = .{ 8.0, 4.0 };
    pub const frame_padding: [2]f32 = .{ 6.0, 3.0 };
    pub const table_cell_padding: [2]f32 = .{ 4.0, 2.0 };

    // ── Indent ───────────────────────────────────────────────────────────────
    pub const tree_indent: f32 = 16.0;
    pub const group_indent: f32 = 12.0;

    // ── Viewport overlay ─────────────────────────────────────────────────────
    pub const viewport_overlay_padding: [2]f32 = .{ 4.0, 4.0 };
    pub const viewport_overlay_item_spacing: [2]f32 = .{ 6.0, 4.0 };
    pub const viewport_mode_item_spacing: [2]f32 = .{ 0.0, 6.0 };
    pub const viewport_hud_window_top_alpha: f32 = 0.26;
    pub const viewport_hud_window_bottom_alpha: f32 = 0.55;
    pub const viewport_hud_window_side_alpha: f32 = 0.12;
    pub const viewport_hud_window_line_thickness: f32 = 1.0;
    pub const viewport_hud_window_line_inset: f32 = 1.0;
    pub const viewport_divider_padding_top: f32 = 3.0;
    pub const viewport_divider_width: f32 = 8.0;
    pub const viewport_divider_alpha: f32 = 0.22;
    pub const viewport_toolbar_item_spacing: [2]f32 = .{ 6.0, 6.0 };
    pub const viewport_window_padding: [2]f32 = .{ 0.0, 4.0 };
    pub const viewport_min_extent: f32 = 8.0;
    pub const viewport_click_threshold_sq: f32 = 16.0;
    pub const viewport_context_drag_threshold_sq: f32 = 16.0;

    // ── Viewport 3D cursor ───────────────────────────────────────────────────
    pub const cursor_3d_scale_factor: f32 = 0.28;
    pub const cursor_3d_ring_radius: f32 = 7.5;
    pub const cursor_3d_ring_pulse: f32 = 2.5;
    pub const cursor_3d_pulse_speed: f32 = 4.6;
    pub const cursor_3d_center_dot_radius: f32 = 4.5;
    pub const cursor_3d_center_ring_bg: [4]f32 = .{ 0.12, 0.12, 0.12, 0.92 };
    pub const cursor_3d_tick_half_length: f32 = 6.0;
    pub const cursor_3d_tick_gap: f32 = 12.0;
    pub const cursor_3d_tick_thickness: f32 = 1.8;
    pub const cursor_3d_label_offset_x: f32 = 13.0;
    pub const cursor_3d_label_padding_x: f32 = 7.0;
    pub const cursor_3d_label_padding_y: f32 = 4.0;
    pub const cursor_3d_label_border_top: f32 = 2.0;
    pub const cursor_3d_label_rounding: f32 = 7.0;
    pub const cursor_3d_label_rounding_top: f32 = 6.0;
    pub const cursor_3d_line_thickness: f32 = 2.0;
    pub const cursor_3d_halo_segments: i32 = 28;
    pub const cursor_3d_dot_segments: i32 = 20;

    // ── Viewport frustum ─────────────────────────────────────────────────────
    pub const frustum_plane_depth_factor: f32 = 1.25;
    pub const frustum_near_clip_margin: f32 = 0.05;
    pub const frustum_ortho_size_factor: f32 = 0.12;
    pub const frustum_ortho_min_scale: f32 = 0.34;
    pub const frustum_ortho_max_scale: f32 = 0.82;
    pub const frustum_ortho_back_depth: f32 = 0.22;
    pub const frustum_ortho_front_depth: f32 = 1.08;
    pub const frustum_chevron_height_factor: f32 = 1.16;

    // ── Viewport entity icons ────────────────────────────────────────────────
    pub const viewport_entity_icon_size_default: f32 = 18.0;
    pub const viewport_entity_icon_size_selected: f32 = 20.0;
    pub const viewport_entity_icon_halo_factor: f32 = 0.72;
    pub const viewport_entity_icon_halo_inner_shrink: f32 = 2.0;
    pub const viewport_entity_icon_halo_selected_glow: f32 = 5.0;
    pub const viewport_entity_icon_halo_primary_glow: f32 = 2.5;
    pub const viewport_entity_icon_halo_hover_glow: f32 = 3.5;
    pub const viewport_entity_icon_halo_selected_alpha: f32 = 0.18;
    pub const viewport_entity_icon_halo_primary_alpha: f32 = 0.24;
    pub const viewport_entity_icon_halo_hover_alpha: f32 = 0.10;
    pub const viewport_entity_icon_segments: i32 = 24;
    pub const viewport_entity_primary_dot_radius: f32 = 3.5;
    pub const viewport_entity_primary_dot_offset: f32 = 0.52;
    pub const viewport_entity_primary_dot_segments: i32 = 16;
    pub const viewport_entity_primary_dot_color: [4]f32 = .{ 0.20, 0.92, 0.58, 0.98 };
    pub const viewport_entity_bg_alpha: f32 = 0.90;
    pub const viewport_entity_inner_alpha: f32 = 0.92;
    pub const viewport_entity_inner_color_factor: f32 = 0.22;
    pub const viewport_entity_bg_rgb: [3]f32 = .{ 0.05, 0.06, 0.08 };
    pub const viewport_entity_hover_glow_color: [4]f32 = .{ 1.0, 1.0, 1.0, 0.10 };

    // ── Viewport mesh edit ───────────────────────────────────────────────────
    pub const mesh_edit_vertex_radius_selected: f32 = 5.2;
    pub const mesh_edit_vertex_radius_default: f32 = 3.4;
    pub const mesh_edit_vertex_segments: i32 = 18;
    pub const mesh_edit_edge_thickness_selected: f32 = 3.0;
    pub const mesh_edit_edge_thickness_default: f32 = 1.2;
    pub const mesh_edit_face_thickness_selected: f32 = 2.6;
    pub const mesh_edit_face_thickness_default: f32 = 1.0;
    pub const mesh_edit_face_dot_radius: f32 = 4.0;
    pub const mesh_edit_face_dot_segments: i32 = 14;
    pub const mesh_edit_wire_thickness_default: f32 = 1.0;

    // ── Viewport playback overlay ────────────────────────────────────────────
    pub const playback_overlay_width: f32 = 140.0;
    pub const playback_overlay_min_margin: f32 = 18.0;
    pub const playback_icon_size: f32 = 12.0;
    pub const playback_icon_button_padding: [2]f32 = .{ 5.0, 3.0 };
    pub const playback_icon_button_rounding: f32 = 3.0;
    pub const playback_icon_tint: [4]u8 = .{ 245, 248, 252, 255 };

    // ── Viewport AI overlay ──────────────────────────────────────────────────
    pub const ai_overlay_width_default: f32 = 280.0;
    pub const ai_overlay_width_waiting: f32 = 320.0;
    pub const ai_overlay_padding: [2]f32 = .{ 4.0, 3.0 };
    pub const ai_overlay_offset_y: f32 = 48.0;
    pub const ai_overlay_detail_max_chars: usize = 44;
    pub const ai_overlay_pulse_speed_waiting: f32 = 2.6;
    pub const ai_overlay_pulse_speed_active: f32 = 3.2;
    pub const ai_overlay_pulse_amplitude: f32 = 0.06;
    pub const ai_overlay_bg_alpha_min: f32 = 0.54;
    pub const ai_overlay_bg_alpha_max: f32 = 0.68;
    pub const ai_overlay_bg_alpha_factor: f32 = 0.72;
    pub const ai_overlay_color_ready: [4]f32 = .{ 0.20, 0.56, 0.36, 0.88 };
    pub const ai_overlay_color_analyzing: [4]f32 = .{ 0.14, 0.38, 0.58, 0.90 };
    pub const ai_overlay_color_compiling: [4]f32 = .{ 0.42, 0.30, 0.12, 0.90 };
    pub const ai_overlay_color_waiting: [4]f32 = .{ 0.38, 0.18, 0.60, 0.94 };
    pub const ai_overlay_stage_label_text: [4]f32 = .{ 0.96, 0.97, 1.0, 1.0 };
    pub const ai_overlay_detail_text: [4]f32 = .{ 0.74, 0.78, 0.86, 0.90 };

    // ── Viewport ghost highlight ─────────────────────────────────────────────
    pub const ghost_highlight_pulse_base: f32 = 0.45;
    pub const ghost_highlight_pulse_amplitude: f32 = 0.55;
    pub const ghost_highlight_text_r: f32 = 0.75;
    pub const ghost_highlight_text_g: f32 = 0.38;
    pub const ghost_highlight_text_b: f32 = 1.0;

    // ── Viewport toolbar ─────────────────────────────────────────────────────
    pub const viewport_toolbar_icon_size: f32 = 14.0;
    pub const viewport_toolbar_frame_padding: [2]f32 = .{ 7.0, 5.0 };
    pub const viewport_toolbar_frame_rounding: f32 = 4.0;
    pub const viewport_toolbar_utility_width: f32 = 90.0;
    pub const viewport_toolbar_accent_tint: [4]u8 = .{ 230, 236, 242, 255 };
    pub const viewport_toolbar_idle_tint: [4]u8 = .{ 168, 174, 182, 255 };

    // ── Viewport overlay buttons ─────────────────────────────────────────────
    pub const overlay_button_min_width: f32 = 50.0;
    pub const overlay_button_text_padding: f32 = 18.0;
    pub const overlay_button_frame_padding: [2]f32 = .{ 7.0, 3.0 };
    pub const overlay_button_frame_rounding: f32 = 3.0;

    // ── Viewport constraints ─────────────────────────────────────────────────
    pub const constraint_chip_min_width: f32 = 44.0;
    pub const constraint_chip_text_padding: f32 = 18.0;
    pub const constraint_snap_step_width: f32 = 88.0;
    pub const constraint_popup_button_width: f32 = 96.0;
    pub const constraint_popup_button_width_bounds_center: f32 = 120.0;
    pub const constraint_popup_button_width_median_point: f32 = 108.0;
    pub const constraint_popup_button_width_active_element: f32 = 120.0;
    pub const constraint_popup_button_width_individual_origins: f32 = 126.0;
    pub const constraint_popup_button_width_place_cursor: f32 = 164.0;
    pub const constraint_popup_button_width_free_axis: f32 = 56.0;
    pub const constraint_popup_button_width_axis: f32 = 40.0;
    pub const constraint_popup_button_width_grid_snap: f32 = 72.0;
    pub const constraint_popup_button_width_surface_snap: f32 = 84.0;
    pub const constraint_popup_button_width_vertex_snap: f32 = 76.0;
    pub const constraint_popup_button_width_align_rotation: f32 = 220.0;
    pub const constraint_cursor_drag_speed: f32 = 0.1;
    pub const constraint_cursor_drag_min: f32 = -100000.0;
    pub const constraint_cursor_drag_max: f32 = 100000.0;
    pub const constraint_translation_snap_speed: f32 = 0.01;
    pub const constraint_translation_snap_min: f32 = 0.01;
    pub const constraint_translation_snap_max: f32 = 1024.0;
    pub const constraint_rotation_snap_speed: f32 = 1.0;
    pub const constraint_rotation_snap_min: f32 = 1.0;
    pub const constraint_rotation_snap_max: f32 = 180.0;
    pub const constraint_scale_snap_speed: f32 = 0.01;
    pub const constraint_scale_snap_min: f32 = 0.01;
    pub const constraint_scale_snap_max: f32 = 10.0;

    // ── Viewport camera frustum colors ───────────────────────────────────────
    pub const frustum_selected_color: [4]f32 = .{ 0.62, 0.88, 1.0, 0.96 };
    pub const frustum_primary_camera_color: [4]f32 = .{ 0.28, 0.92, 0.60, 0.92 };
    pub const frustum_default_color: [4]f32 = .{ 0.47, 0.78, 1.0, 0.66 };
    pub const frustum_thickness_selected: f32 = 2.0;
    pub const frustum_thickness_primary: f32 = 1.8;
    pub const frustum_thickness_default: f32 = 1.35;

    // ── Viewport 3D cursor colors ────────────────────────────────────────────
    pub const cursor_3d_x_color: [4]f32 = .{ 0.96, 0.42, 0.42, 0.95 };
    pub const cursor_3d_y_color: [4]f32 = .{ 0.48, 0.92, 0.54, 0.95 };
    pub const cursor_3d_z_color: [4]f32 = .{ 0.44, 0.68, 0.98, 0.95 };
    pub const cursor_3d_center_color: [4]f32 = .{ 0.98, 0.92, 0.42, 0.98 };
    pub const cursor_3d_halo_color: [4]f32 = .{ 0.96, 0.86, 0.34, 0.24 };
    pub const cursor_3d_label_bg: [4]f32 = .{ 0.07, 0.08, 0.10, 0.88 };
    pub const cursor_3d_label_border: [4]f32 = .{ 0.93, 0.84, 0.34, 0.30 };
    pub const cursor_3d_label_text: [4]f32 = .{ 0.96, 0.95, 0.88, 0.98 };

    // ── Viewport mesh edit colors ────────────────────────────────────────────
    pub const mesh_edit_selected_color: [4]f32 = .{ 0.98, 0.84, 0.32, 0.96 };
    pub const mesh_edit_accent_color: [4]f32 = .{ 0.42, 0.86, 0.78, 0.92 };
    pub const mesh_edit_muted_color: [4]f32 = .{ 0.54, 0.62, 0.72, 0.34 };

    // ── Viewport entity icon tints ───────────────────────────────────────────
    pub const viewport_entity_tint_camera: [4]u8 = .{ 122, 208, 255, 255 };
    pub const viewport_entity_tint_directional: [4]u8 = .{ 255, 212, 92, 255 };
    pub const viewport_entity_tint_point: [4]u8 = .{ 255, 224, 116, 255 };
    pub const viewport_entity_tint_spot: [4]u8 = .{ 132, 204, 255, 255 };
    pub const viewport_entity_accent_camera: [4]f32 = .{ 0.34, 0.77, 1.0, 1.0 };
    pub const viewport_entity_accent_directional: [4]f32 = .{ 1.0, 0.82, 0.36, 1.0 };
    pub const viewport_entity_accent_point: [4]f32 = .{ 1.0, 0.90, 0.46, 1.0 };
    pub const viewport_entity_accent_spot: [4]f32 = .{ 0.57, 0.82, 1.0, 1.0 };

    // ── Viewport HUD palettes ────────────────────────────────────────────────
    pub const hud_button_bg: [4]f32 = .{ 0.15, 0.16, 0.18, 0.90 };
    pub const hud_button_hovered: [4]f32 = .{ 0.20, 0.22, 0.25, 0.96 };
    pub const hud_button_active: [4]f32 = .{ 0.12, 0.14, 0.17, 1.0 };
    pub const hud_active_button_bg: [4]f32 = .{ 0.20, 0.60, 0.45, 0.20 };
    pub const hud_active_button_hovered: [4]f32 = .{ 0.24, 0.68, 0.52, 0.30 };
    pub const hud_active_button_active: [4]f32 = .{ 0.16, 0.52, 0.38, 0.42 };

    // ── Viewport overlay text colors ─────────────────────────────────────────
    pub const overlay_status_chip_text: [4]f32 = .{ 0.74, 0.77, 0.82, 1.0 };
    pub const overlay_title_chip_text: [4]f32 = .{ 0.95, 0.97, 0.99, 1.0 };
    pub const overlay_ai_detail_text: [4]f32 = .{ 0.96, 0.97, 1.0, 1.0 };

    // ── Viewport entity button ───────────────────────────────────────────────
    pub const viewport_entity_button_padding: [2]f32 = .{ 0.0, 0.0 };
    pub const viewport_entity_button_rounding: f32 = 0.0;

    // ── Viewport placement ───────────────────────────────────────────────────
    pub const spawn_raycast_max_distance: f32 = 2048.0;
    pub const spawn_sweep_offset: f32 = 0.05;
    pub const spawn_sweep_extra: f32 = 0.5;
    pub const spawn_plane_y: f32 = 0.0;

    // ── Viewport projection ──────────────────────────────────────────────────
    pub const ndc_clip_margin: f32 = 0.15;
    pub const ndc_clip_near_threshold: f32 = 0.00001;

    // ── Inspector ────────────────────────────────────────────────────────────
    pub const inspector_section_dummy: f32 = 4.0;
    pub const inspector_axis_spacing: f32 = 3.0;
    pub const inspector_axis_width_min: f32 = 22.0;
    pub const inspector_axis_frame_rounding: f32 = 0.0;
    pub const inspector_item_spacing_table: [2]f32 = .{ 10.0, 8.0 };
    pub const inspector_item_spacing_stacked: [2]f32 = .{ 10.0, 6.0 };
    pub const inspector_action_button_min_width: f32 = 80.0;
    pub const inspector_section_gap: f32 = 6.0;
    pub const inspector_toggle_width: f32 = 72.0;
    pub const inspector_projection_toggle_width: f32 = 116.0;
    pub const inspector_summary_min_width: f32 = 220.0;
    pub const inspector_summary_min_height: f32 = 120.0;
    pub const inspector_name_buffer_size: usize = 80;
    pub const inspector_filter_buffer_size: usize = 32;
    pub const inspector_entity_name_text_color: [4]f32 = .{ 0.88, 0.92, 0.98, 1.0 };
    pub const inspector_ai_preview_text_color: [4]f32 = .{ 0.78, 0.50, 1.0, 0.80 };
    pub const inspector_axis_x_bg: [4]f32 = .{ 0.82, 0.23, 0.23, 1.0 };
    pub const inspector_axis_y_bg: [4]f32 = .{ 0.16, 0.59, 0.44, 1.0 };
    pub const inspector_axis_z_bg: [4]f32 = .{ 0.20, 0.45, 0.85, 1.0 };
    pub const inspector_axis_text: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 };
    pub const inspector_prefab_button_width: f32 = 120.0;
    pub const inspector_camera_fov_speed: f32 = 0.25;
    pub const inspector_camera_fov_min: f32 = 10.0;
    pub const inspector_camera_fov_max: f32 = 170.0;
    pub const inspector_camera_near_speed: f32 = 0.01;
    pub const inspector_camera_near_min: f32 = 0.001;
    pub const inspector_camera_near_max: f32 = 100.0;
    pub const inspector_camera_far_speed: f32 = 1.0;
    pub const inspector_camera_far_min: f32 = 0.1;
    pub const inspector_camera_far_max: f32 = 5000.0;
    pub const inspector_camera_ortho_speed: f32 = 0.1;
    pub const inspector_camera_ortho_min: f32 = 0.01;
    pub const inspector_camera_ortho_max: f32 = 500.0;
    pub const inspector_camera_ortho_clip_speed: f32 = 0.05;
    pub const inspector_camera_ortho_clip_min: f32 = -1000.0;
    pub const inspector_camera_ortho_clip_max: f32 = 1000.0;
    pub const inspector_light_intensity_speed: f32 = 0.1;
    pub const inspector_light_intensity_min: f32 = 0.0;
    pub const inspector_light_intensity_max: f32 = 100.0;
    pub const inspector_light_range_speed: f32 = 0.1;
    pub const inspector_light_range_min: f32 = 0.1;
    pub const inspector_light_range_max: f32 = 100.0;
    pub const inspector_audio_volume_speed: f32 = 0.01;
    pub const inspector_audio_volume_min: f32 = 0.0;
    pub const inspector_audio_volume_max: f32 = 1.0;
    pub const inspector_audio_min_dist_speed: f32 = 0.1;
    pub const inspector_audio_min_dist_min: f32 = 0.0;
    pub const inspector_audio_min_dist_max: f32 = 1000.0;
    pub const inspector_audio_max_dist_speed: f32 = 0.1;
    pub const inspector_audio_max_dist_min: f32 = 0.0;
    pub const inspector_audio_max_dist_max: f32 = 10000.0;
    pub const inspector_audio_doppler_speed: f32 = 0.01;
    pub const inspector_audio_doppler_min: f32 = 0.0;
    pub const inspector_audio_doppler_max: f32 = 5.0;

    // ── Hierarchy ────────────────────────────────────────────────────────────
    pub const hierarchy_filter_right_margin: f32 = 40.0;
    pub const hierarchy_filter_compact_threshold: f32 = 180.0;
    pub const hierarchy_selection_count_spacing: f32 = 8.0;
    pub const hierarchy_window_padding: [2]f32 = .{ 0.0, 4.0 };
    pub const hierarchy_rename_buffer_size: usize = 128;

    // ── Content Browser ─────────────────────────────────────────────────────
    pub const content_browser_window_padding: [2]f32 = .{ 0.0, 0.0 };
    pub const content_browser_drawer_content_padding: [2]f32 = .{ 10.0, 10.0 };
    pub const content_browser_header_item_spacing: [2]f32 = .{ 8.0, 6.0 };
    pub const content_browser_tab_padding: [2]f32 = .{ 12.0, 5.0 };

    // ── Timeline ────────────────────────────────────────────────────────────
    pub const timeline_item_spacing: [2]f32 = .{ 4.0, 0.0 };
    pub const timeline_node_padding: [2]f32 = .{ 10.0, 6.0 };

    // ── Place Actor ─────────────────────────────────────────────────────────
    pub const place_actor_row_padding: [2]f32 = .{ 6.0, 4.0 };

    // ── Settings ────────────────────────────────────────────────────────────
    pub const settings_window_item_spacing: [2]f32 = .{ 8.0, 4.0 };
    pub const settings_sidebar_padding: [2]f32 = .{ 0.0, 4.0 };

    // ── AI Chat ─────────────────────────────────────────────────────────────
    pub const ai_chat_message_padding: [2]f32 = .{ 12.0, 10.0 };
    pub const ai_chat_chip_padding: [2]f32 = .{ 10.0, 6.0 };
    pub const ai_chat_setup_padding: [2]f32 = .{ 16.0, 14.0 };
    pub const ai_chat_composer_padding: [2]f32 = .{ 10.0, 10.0 };

    // ── Layout ───────────────────────────────────────────────────────────────
    pub const layout_divider_spacing: f32 = 6.0;
    pub const layout_label_width_min: f32 = 86.0;
    pub const layout_label_width_max: f32 = 142.0;
    pub const layout_label_width_ratio: f32 = 0.34;
    pub const layout_property_label_dimmed: [4]f32 = .{ 0.64, 0.68, 0.74, 1.0 };
    pub const layout_min_button_width: f32 = 80.0;
    pub const layout_min_button_width_small: f32 = 60.0;

    // ── Menu bar ─────────────────────────────────────────────────────────────
    pub const menu_bar_drag_region_min_width: f32 = 48.0;
    pub const menu_bar_restore_click_offset_min: f32 = 8.0;
    pub const menu_bar_restore_click_offset_max: f32 = 28.0;
    pub const menu_bar_restore_click_ratio_min: f32 = 0.1;
    pub const menu_bar_restore_click_ratio_max: f32 = 0.9;

    // ── Playback ─────────────────────────────────────────────────────────────
    pub const playback_idle_button_bg: [4]f32 = .{ 0.20, 0.22, 0.25, 0.76 };
    pub const playback_idle_button_hovered: [4]f32 = .{ 0.24, 0.27, 0.31, 0.82 };
    pub const playback_idle_button_active: [4]f32 = .{ 0.18, 0.20, 0.24, 0.88 };
    pub const playback_play_button_bg: [4]f32 = .{ 0.30, 0.35, 0.34, 0.80 };
    pub const playback_play_button_hovered: [4]f32 = .{ 0.34, 0.40, 0.38, 0.86 };
    pub const playback_play_button_active: [4]f32 = .{ 0.28, 0.32, 0.31, 0.92 };
    pub const playback_pause_button_bg: [4]f32 = .{ 0.32, 0.30, 0.25, 0.80 };
    pub const playback_pause_button_hovered: [4]f32 = .{ 0.36, 0.34, 0.29, 0.86 };
    pub const playback_pause_button_active: [4]f32 = .{ 0.29, 0.27, 0.23, 0.92 };
    pub const playback_step_button_bg: [4]f32 = .{ 0.24, 0.26, 0.30, 0.78 };
    pub const playback_step_button_hovered: [4]f32 = .{ 0.28, 0.31, 0.36, 0.84 };
    pub const playback_step_button_active: [4]f32 = .{ 0.22, 0.24, 0.28, 0.90 };

    // ── Segmented buttons ────────────────────────────────────────────────────
    pub const segmented_button_rounding: f32 = 4.0;
    pub const segmented_button_rounding_middle: f32 = 0.0;
    pub const segmented_button_width_object_mode: f32 = 66.0;
    pub const segmented_button_width_edit_mode: f32 = 58.0;
    pub const segmented_button_width_vertex_mode: f32 = 54.0;
    pub const segmented_button_width_edge_mode: f32 = 46.0;
    pub const segmented_button_width_face_mode: f32 = 46.0;

    // ── Property row ─────────────────────────────────────────────────────────
    pub const property_row_dummy_after_label: f32 = 2.0;

    // ── Toolbar ──────────────────────────────────────────────────────────────
    pub const toolbar_playback_button_size: f32 = 28.0;
    pub const toolbar_playback_icon_size: f32 = 20.0;
    pub const toolbar_playback_item_spacing: f32 = 6.0;
    pub const toolbar_playback_white_tint: [4]u8 = .{ 255, 255, 255, 255 };
    pub const toolbar_window_control_height: f32 = 1.0;

    // ── Mesh edit overlay ────────────────────────────────────────────────────
    pub const mesh_edit_overlay_line_thickness_default: f32 = 1.0;

    // ── ViewCube ─────────────────────────────────────────────────────────────
    pub const view_cube_corner_radius: f32 = 4.0;
    pub const view_cube_axis_label_padding: f32 = 4.0;
    pub const view_cube_axis_label_rounding: f32 = 3.0;
    pub const view_cube_axis_label_alpha: f32 = 0.85;
    pub const view_cube_face_alpha: f32 = 0.40;
    pub const view_cube_face_hovered_alpha: f32 = 0.55;
    pub const view_cube_edge_thickness: f32 = 1.5;
    pub const view_cube_edge_alpha: f32 = 0.30;
    pub const view_cube_bg_alpha: f32 = 0.38;
    pub const view_cube_bg_rounding: f32 = 6.0;
    pub const view_cube_padding: f32 = 4.0;
    pub const view_cube_label_font_scale: f32 = 0.85;
    pub const view_cube_face_color: [4]f32 = .{ 0.18, 0.20, 0.24, 0.40 };
    pub const view_cube_face_hovered_color: [4]f32 = .{ 0.22, 0.24, 0.28, 0.55 };
    pub const view_cube_edge_color: [4]f32 = .{ 0.40, 0.44, 0.50, 0.30 };
    pub const view_cube_bg_color: [4]f32 = .{ 0.08, 0.09, 0.12, 0.38 };
    pub const view_cube_label_bg: [4]f32 = .{ 0.12, 0.13, 0.16, 0.85 };
    pub const view_cube_label_text: [4]f32 = .{ 0.88, 0.90, 0.94, 1.0 };
    pub const view_cube_axis_x: [4]f32 = .{ 0.85, 0.20, 0.20, 0.85 };
    pub const view_cube_axis_y: [4]f32 = .{ 0.20, 0.70, 0.30, 0.85 };
    pub const view_cube_axis_z: [4]f32 = .{ 0.25, 0.50, 0.90, 0.85 };

    // ── FPS overlay ──────────────────────────────────────────────────────────
    pub const fps_overlay_padding: [2]f32 = .{ 4.0, 3.0 };
    pub const fps_overlay_bg_alpha: f32 = 0.38;
    pub const fps_overlay_text_color: [4]f32 = .{ 0.74, 0.77, 0.82, 1.0 };
    pub const fps_overlay_value_color: [4]f32 = .{ 0.90, 0.92, 0.96, 1.0 };
    pub const fps_overlay_min_width: f32 = 120.0;
    pub const fps_overlay_margin: f32 = 14.0;
    pub const fps_overlay_item_spacing: [2]f32 = .{ 8.0, 2.0 };
    pub const fps_overlay_refresh_dot_radius: f32 = 3.0;
    pub const fps_overlay_refresh_dot_offset: f32 = 5.0;
    pub const fps_overlay_refresh_dot_segments: i32 = 12;
    pub const fps_overlay_refresh_dot_color: [4]f32 = .{ 0.30, 0.60, 0.90, 0.90 };
    pub const fps_overlay_sample_interval: f32 = 0.20;
    pub const fps_overlay_height: f32 = 20.0;
    pub const fps_overlay_bottom_offset: f32 = 24.0;

    // ── ViewCube extras ──────────────────────────────────────────────────────
    pub const view_cube_size_ratio: f32 = 0.13;
    pub const view_cube_top_offset_extra: f32 = 6.0;
};

// ── Typography ───────────────────────────────────────────────────────────────

pub const Typography = struct {
    // ── Font sizes ───────────────────────────────────────────────────────────
    pub const base_size: f32 = 13.0;
    pub const small_size: f32 = 11.0;
    pub const large_size: f32 = 15.0;

    // ── Line heights ─────────────────────────────────────────────────────────
    pub const line_height: f32 = 18.0;
    pub const line_height_small: f32 = 14.0;
    pub const line_height_large: f32 = 22.0;

    // ── Text hierarchy ───────────────────────────────────────────────────────
    pub const heading: Color = Palette.text_bright;
    pub const body: Color = Palette.text_primary;
    pub const secondary: Color = Palette.text_secondary;
    pub const muted: Color = Palette.text_muted;
};

// ── Sizes ────────────────────────────────────────────────────────────────────

pub const Size = struct {
    // ── Icons ────────────────────────────────────────────────────────────────
    pub const icon_xs: f32 = 12.0;
    pub const icon_sm: f32 = 16.0;
    pub const icon_md: f32 = 20.0;
    pub const icon_lg: f32 = 24.0;
    pub const icon_xl: f32 = 32.0;

    // Hierarchy (legacy aliases)
    pub const hierarchy_icon: f32 = 16.0;
    pub const status_button_extent: f32 = 26.0;
    pub const status_column_width: f32 = 32.0;
    pub const drag_preview_icon: f32 = 20.0;

    // Icon padding
    pub const compact_icon_padding: [2]f32 = .{ 3.0, 3.0 };
    pub const regular_icon_padding: [2]f32 = .{ 5.0, 5.0 };

    // ── Controls ─────────────────────────────────────────────────────────────
    pub const control_height: f32 = 28.0;
    pub const control_height_small: f32 = 22.0;
    pub const control_height_large: f32 = 36.0;
    pub const button_min_width: f32 = 60.0;
    pub const input_min_width: f32 = 80.0;

    // ── Inspector property grid ──────────────────────────────────────────────
    pub const stacked_grid_min_width: f32 = 320.0;
    pub const transform_grid_min_width: f32 = 360.0;

    // ── Layout ───────────────────────────────────────────────────────────────
    pub const section_padding: f32 = 14.0;
    pub const item_spacing: f32 = 10.0;
    pub const row_spacing: f32 = 8.0;

    // ── Window constraints ───────────────────────────────────────────────────
    pub const panel_min_width: f32 = 220.0;
    pub const panel_min_height: f32 = 120.0;

    // ── Viewport ─────────────────────────────────────────────────────────────
    pub const view_cube_size_min: f32 = 72.0;
    pub const view_cube_size_max: f32 = 92.0;
    pub const view_cube_margin: f32 = 20.0;
    pub const overlay_top_inset: f32 = 14.0;
    pub const overlay_icon_size: f32 = 14.0;
    pub const overlay_progress_width: f32 = 116.0;
    pub const bottom_drawer_bar_height: f32 = 38.0;
    pub const bottom_overlay_gap: f32 = 18.0;
    pub const overlay_bg_alpha: f32 = 0.38;

    // ── Toolbar ──────────────────────────────────────────────────────────────
    pub const toolbar_icon_size: f32 = 20.0;
    pub const toolbar_play_button_size: f32 = 28.0;
    pub const toolbar_item_spacing: f32 = 6.0;

    // ── Menu ─────────────────────────────────────────────────────────────────
    pub const menu_bar_height: f32 = 22.0;
    pub const menu_item_height: f32 = 24.0;
    pub const menu_double_click_interval: f32 = 0.35;
    pub const menu_double_click_max_dist: f32 = 6.0;
    pub const menu_drag_start_dist: f32 = 4.0;
    pub const menu_trailing_button_reserve: f32 = 114.0;

    // ── Inspector ────────────────────────────────────────────────────────────
    pub const transform_label_width: f32 = 42.0;
    pub const transform_drag_speed: f32 = 0.05;
    pub const transform_drag_min: f32 = -500.0;
    pub const transform_drag_max: f32 = 500.0;
    pub const rotation_drag_speed: f32 = 0.01;
    pub const scale_drag_speed: f32 = 0.01;
    pub const scale_drag_min: f32 = 0.05;
    pub const scale_drag_max: f32 = 100.0;
    pub const inspector_toggle_width: f32 = 72.0;
    pub const inspector_projection_toggle_width: f32 = 116.0;
    pub const inspector_action_button_min_width: f32 = 80.0;

    // ── Hierarchy ────────────────────────────────────────────────────────────
    pub const hierarchy_filter_compact_threshold: f32 = 180.0;
    pub const hierarchy_filter_right_margin: f32 = 40.0;
    pub const hierarchy_max_depth: usize = 32;
    pub const hierarchy_unparent_spacing: f32 = 4.0;
};

// ── Border Radius ────────────────────────────────────────────────────────────

pub const BorderRadius = struct {
    // ── Controls ─────────────────────────────────────────────────────────────
    pub const control: f32 = 2.0;
    pub const button: f32 = 2.0;
    pub const frame: f32 = 2.0;
    pub const popup: f32 = 4.0;
    pub const window: f32 = 2.0;

    // ── Icons ────────────────────────────────────────────────────────────────
    pub const compact_icon_rounding: f32 = 6.0;
    pub const regular_icon_rounding: f32 = 8.0;

    // ── Special ──────────────────────────────────────────────────────────────
    pub const thumbnail: f32 = 4.0;
    pub const badge: f32 = 8.0;
    pub const progress: f32 = 2.0;
    pub const timeline_node: f32 = 7.0;
    pub const ai_input: f32 = 7.0;
    pub const pill: f32 = 999.0;
    pub const place_actor_card: f32 = 5.0;
};

// ── Style Helpers ────────────────────────────────────────────────────────────

/// Select a button palette based on an active/inactive flag.
pub fn statusPalette(active: bool) ButtonPalette {
    return if (active) Palette.status.on else Palette.status.off;
}

/// Select an icon tint based on entity state flags.
pub fn hierarchyIconTint(opts: struct {
    selected: bool = false,
    frozen: bool = false,
    visible: bool = true,
}) IconTint {
    if (opts.selected) return Palette.hierarchy.selected_icon;
    if (opts.frozen) return Palette.hierarchy.frozen_icon;
    if (opts.visible) return Palette.hierarchy.active_icon;
    return Palette.hierarchy.dimmed_icon;
}

/// Select icon padding/rounding based on button size.
pub fn iconPadding(size: f32) [2]f32 {
    return if (size >= 28.0) Size.regular_icon_padding else Size.compact_icon_padding;
}

pub fn iconRounding(size: f32) f32 {
    return if (size >= 28.0) Size.regular_icon_rounding else Size.compact_icon_rounding;
}
