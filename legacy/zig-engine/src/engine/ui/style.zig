///! Visual style properties for UI nodes.
const std = @import("std");

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1, .a = 1 };
    pub const yellow = Color{ .r = 1, .g = 1, .b = 0, .a = 1 };

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1 };
    }

    pub fn hex(comptime code: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((code >> 16) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((code >> 8) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt(code & 0xFF)) / 255.0,
            .a = 1,
        };
    }

    pub fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    pub fn toArray(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }
};

pub const TextAlign = enum {
    left,
    center,
    right,
};

pub const TextBaseline = enum {
    top,
    middle,
    bottom,
};

pub const Overflow = enum {
    visible,
    hidden,
    scroll,
};

pub const Style = struct {
    // Background
    background: Color = Color.transparent,
    // Border
    border_color: Color = Color.transparent,
    border_width: f32 = 0,
    border_radius: f32 = 0,
    // Opacity
    opacity: f32 = 1.0,
    // Text
    font_size: f32 = 16.0,
    text_color: Color = Color.white,
    text_align: TextAlign = .left,
    text_baseline: TextBaseline = .top,
    line_height: f32 = 1.2,
    // Overflow
    overflow: Overflow = .visible,
};
