// host/canvas.zig — Canvas/UI 控件桥接
//
// 将脚本世界的 C ABI 调用映射到 ui.Canvas 实际方法。
// userdata → GuavaHostContext → ScriptContext → ui_canvas (anyopaque → *Canvas)

const host = @import("mod.zig");
const ui_canvas_mod = @import("../../ui/canvas.zig");

const Canvas = ui_canvas_mod.Canvas;
const Color = ui_canvas_mod.Color;
const Dimension = ui_canvas_mod.Dimension;

/// 从 userdata 获取 Canvas 指针。
inline fn getCanvas(userdata: ?*anyopaque) ?*Canvas {
    const ctx = host.activeContext(userdata) orelse return null;
    const ptr = ctx.ui_canvas orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// ═══════════════════════════════════════════════════════════════════════════
// Canvas Host Functions
// ═══════════════════════════════════════════════════════════════════════════

/// 移除根节点下所有子节点（清空画布）
pub fn guavaHostCanvasClear(userdata: ?*anyopaque) callconv(.c) void {
    const canvas = getCanvas(userdata) orelse return;
    // Destroy all children of root
    const root = canvas.pool.get(canvas.root_id) orelse return;
    var child_opt = root.first_child;
    while (child_opt) |cid| {
        const next = if (canvas.pool.get(cid)) |c| c.next_sibling else null;
        canvas.destroyNode(cid);
        child_opt = next;
    }
}

/// 创建文本节点 → 返回节点 id (0 = 失败)
pub fn guavaHostCanvasAddText(
    userdata: ?*anyopaque,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    text_ptr: [*]const u8,
    text_len: usize,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) callconv(.c) u32 {
    const canvas = getCanvas(userdata) orelse return 0;
    const text = text_ptr[0..text_len];
    const color = Color{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = @as(f32, @floatFromInt(a)) / 255.0,
    };
    const node = canvas.addLabel(.{
        .text = text,
        .color = color,
        .font_size = h,
    }) catch return 0;
    node.layout.position = .absolute;
    node.layout.anchor_left = x;
    node.layout.anchor_top = y;
    node.layout.width = .{ .px = w };
    canvas.appendToRoot(node.id);
    canvas.dirty = true;
    return node.id;
}

/// 创建面板节点 → 返回节点 id
pub fn guavaHostCanvasAddPanel(
    userdata: ?*anyopaque,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) callconv(.c) u32 {
    const canvas = getCanvas(userdata) orelse return 0;
    const bg = Color{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = @as(f32, @floatFromInt(a)) / 255.0,
    };
    const node = canvas.addPanel(.{
        .x = x,
        .y = y,
        .width = .{ .px = w },
        .height = .{ .px = h },
        .background = bg,
    }) catch return 0;
    return node.id;
}

/// 创建按钮节点（面板 + 子文本）→ 返回面板节点 id
pub fn guavaHostCanvasAddButton(
    userdata: ?*anyopaque,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    text_ptr: [*]const u8,
    text_len: usize,
) callconv(.c) u32 {
    const canvas = getCanvas(userdata) orelse return 0;
    const text = text_ptr[0..text_len];
    // 按钮 = 带交互的面板 + 居中文本标签
    const panel = canvas.addPanel(.{
        .x = x,
        .y = y,
        .width = .{ .px = w },
        .height = .{ .px = h },
        .background = Color{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 0.9 },
        .border_radius = 4,
    }) catch return 0;
    panel.interactive = true;
    _ = canvas.addLabel(.{
        .parent = panel.id,
        .text = text,
        .color = Color.white,
        .font_size = 14,
    }) catch return 0;
    return panel.id;
}

/// 创建进度条节点 → 返回节点 id
pub fn guavaHostCanvasAddProgressBar(
    userdata: ?*anyopaque,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    progress: f32,
) callconv(.c) u32 {
    const canvas = getCanvas(userdata) orelse return 0;
    // 背景面板
    const bg = canvas.addPanel(.{
        .x = x,
        .y = y,
        .width = .{ .px = w },
        .height = .{ .px = h },
        .background = Color{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 0.8 },
    }) catch return 0;
    // 填充条（子节点，宽度按百分比）
    const clamped = @min(@max(progress, 0.0), 1.0);
    const fill = canvas.addPanel(.{
        .width = .{ .px = w * clamped },
        .height = .{ .px = h },
        .background = Color{ .r = 0.2, .g = 0.8, .b = 0.4, .a = 1.0 },
    }) catch return 0;
    canvas.appendChild(bg.id, fill.id);
    // 存储填充条 id 在 user_data（以便 setProgress 更新宽度）
    bg.user_data = @ptrFromInt(@as(usize, fill.id));
    return bg.id;
}

/// 修改文本节点的内容
pub fn guavaHostCanvasSetText(userdata: ?*anyopaque, node_id: u32, text_ptr: [*]const u8, text_len: usize) callconv(.c) void {
    const canvas = getCanvas(userdata) orelse return;
    const node = canvas.getNode(node_id) orelse return;
    node.text = text_ptr[0..text_len];
    canvas.dirty = true;
}

/// 修改进度条的填充比例（0..1）
pub fn guavaHostCanvasSetProgress(userdata: ?*anyopaque, node_id: u32, progress: f32) callconv(.c) void {
    const canvas = getCanvas(userdata) orelse return;
    const bg_node = canvas.getNode(node_id) orelse return;
    // 从 user_data 取回填充条 id
    const fill_id: u32 = @intCast(@intFromPtr(bg_node.user_data orelse return));
    const fill_node = canvas.getNode(fill_id) orelse return;
    const clamped = @min(@max(progress, 0.0), 1.0);
    // 根据背景宽度重算填充宽度
    const bg_w = switch (bg_node.layout.width) {
        .px => |v| v,
        else => 100.0,
    };
    fill_node.layout.width = .{ .px = bg_w * clamped };
    canvas.dirty = true;
}

/// 设置节点可见性（visible != 0 → true）
pub fn guavaHostCanvasSetVisible(userdata: ?*anyopaque, node_id: u32, visible: u32) callconv(.c) void {
    const canvas = getCanvas(userdata) orelse return;
    const node = canvas.getNode(node_id) orelse return;
    node.visible = (visible != 0);
    canvas.dirty = true;
}

/// 移除节点及其子树
pub fn guavaHostCanvasRemoveWidget(userdata: ?*anyopaque, node_id: u32) callconv(.c) void {
    const canvas = getCanvas(userdata) orelse return;
    canvas.destroyNode(node_id);
}

/// 检查按钮是否被点击（当前帧）；由于输入事件在脚本端处理前
/// 已由引擎 hitTest 设置 hovered 状态，此处简化为返回 hovered
pub fn guavaHostCanvasWasButtonClicked(userdata: ?*anyopaque, node_id: u32) callconv(.c) u32 {
    const canvas = getCanvas(userdata) orelse return 0;
    const node = canvas.getNode(node_id) orelse return 0;
    return if (node.hovered and node.interactive) @as(u32, 1) else @as(u32, 0);
}
