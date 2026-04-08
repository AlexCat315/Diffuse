// host/canvas.zig — Canvas/UI 控件桥接（占位实现）

pub fn guavaHostCanvasClear(_: ?*anyopaque) callconv(.c) void {}

pub fn guavaHostCanvasAddText(_: ?*anyopaque, _: f32, _: f32, _: f32, _: f32, _: [*]const u8, _: usize, _: u8, _: u8, _: u8, _: u8) callconv(.c) u32 {
    return 0;
}

pub fn guavaHostCanvasAddPanel(_: ?*anyopaque, _: f32, _: f32, _: f32, _: f32, _: u8, _: u8, _: u8, _: u8) callconv(.c) u32 {
    return 0;
}

pub fn guavaHostCanvasAddButton(_: ?*anyopaque, _: f32, _: f32, _: f32, _: f32, _: [*]const u8, _: usize) callconv(.c) u32 {
    return 0;
}

pub fn guavaHostCanvasAddProgressBar(_: ?*anyopaque, _: f32, _: f32, _: f32, _: f32, _: f32) callconv(.c) u32 {
    return 0;
}

pub fn guavaHostCanvasSetText(_: ?*anyopaque, _: u32, _: [*]const u8, _: usize) callconv(.c) void {}

pub fn guavaHostCanvasSetProgress(_: ?*anyopaque, _: u32, _: f32) callconv(.c) void {}

pub fn guavaHostCanvasSetVisible(_: ?*anyopaque, _: u32, _: u32) callconv(.c) void {}

pub fn guavaHostCanvasRemoveWidget(_: ?*anyopaque, _: u32) callconv(.c) void {}

pub fn guavaHostCanvasWasButtonClicked(_: ?*anyopaque, _: u32) callconv(.c) u32 {
    return 0;
}
