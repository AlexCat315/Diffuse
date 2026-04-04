///! handlers/rendersettings.zig — viewport render settings.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

const schema_types = @import("../schema/types.zig");
const ShadingMode = schema_types.ViewportShadingMode;
const TransformSpace = schema_types.TransformSpace;
const ResolutionPreset = enum { viewport, hd_1080, dci_2k, uhd_4k, custom };

const OutputFormat = enum { png, exr, jpg };

// Static viewport settings (EditorState not accessible from RPC)
var shading_mode: ShadingMode = .rendered;
var transform_space: TransformSpace = .local;
var show_grid: bool = true;
var show_bones: bool = false;
var show_collision: bool = false;
var pt_samples: u32 = 12;
var pt_bounces: u32 = 4;
var pt_resolution_scale: f32 = 1.0;
var render_output_preset: ResolutionPreset = .hd_1080;
var render_output_width: u32 = 1920;
var render_output_height: u32 = 1080;
var render_output_format: OutputFormat = .png;
var render_output_path: [256]u8 = init_path();
var render_output_path_len: usize = 0;

fn init_path() [256]u8 {
    return std.mem.zeroes([256]u8);
}

fn presetDisplayName(p: ResolutionPreset) []const u8 {
    return switch (p) {
        .viewport => "viewport",
        .hd_1080 => "1080p",
        .dci_2k => "1440p",
        .uhd_4k => "4k",
        .custom => "custom",
    };
}

pub fn getSettings(ctx: *Ctx) !void {
    const vp_size = ctx.layer.renderer.sceneViewportSize();
    const dims = resolveOutputDimensions(vp_size);
    try ctx.reply(.{
        .shadingMode = @tagName(shading_mode),
        .transformSpace = @tagName(transform_space),
        .showGrid = show_grid,
        .showBones = show_bones,
        .showCollision = show_collision,
        .pathTrace = .{
            .samples = pt_samples,
            .bounces = pt_bounces,
            .resolutionScale = pt_resolution_scale,
        },
        .viewportSize = .{ .width = vp_size[0], .height = vp_size[1] },
        .renderOutput = .{
            .preset = presetDisplayName(render_output_preset),
            .width = dims[0],
            .height = dims[1],
            .format = @tagName(render_output_format),
            .path = render_output_path[0..render_output_path_len],
        },
    });
}

pub fn setShadingMode(ctx: *Ctx) !void {
    const mode_str = try ctx.param([]const u8, "mode");
    if (strEql(mode_str, "solid")) {
        shading_mode = .solid;
    } else if (strEql(mode_str, "material")) {
        shading_mode = .material;
    } else if (strEql(mode_str, "rendered")) {
        shading_mode = .rendered;
    } else if (strEql(mode_str, "wireframe")) {
        shading_mode = .wireframe;
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

pub fn setTransformSpace(ctx: *Ctx) !void {
    const space_str = try ctx.param([]const u8, "space");
    if (strEql(space_str, "local")) {
        transform_space = .local;
    } else if (strEql(space_str, "world")) {
        transform_space = .world;
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

pub fn setOverlay(ctx: *Ctx) !void {
    const key = try ctx.param([]const u8, "key");
    const val = try ctx.param(bool, "value");
    if (strEql(key, "showGrid")) {
        show_grid = val;
    } else if (strEql(key, "showBones")) {
        show_bones = val;
    } else if (strEql(key, "showCollision")) {
        show_collision = val;
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

pub fn setPathTrace(ctx: *Ctx) !void {
    if (try ctx.paramOpt(u64, "samples")) |v| {
        pt_samples = @intCast(std.math.clamp(v, 1, 4096));
    }
    if (try ctx.paramOpt(u64, "bounces")) |v| {
        pt_bounces = @intCast(std.math.clamp(v, 1, 12));
    }
    if (try ctx.paramOpt(f32, "resolutionScale")) |v| {
        pt_resolution_scale = std.math.clamp(v, 0.25, 1.0);
    }
    ctx.layer.renderer.resetPathTraceState();
    try ctx.reply(.{});
}

pub fn applyPtPreset(ctx: *Ctx) !void {
    const name = try ctx.param([]const u8, "preset");
    if (strEql(name, "preview")) {
        pt_samples = 1;
        pt_bounces = 1;
        pt_resolution_scale = 0.5;
    } else if (strEql(name, "low")) {
        pt_samples = 4;
        pt_bounces = 2;
        pt_resolution_scale = 0.75;
    } else if (strEql(name, "medium")) {
        pt_samples = 12;
        pt_bounces = 4;
        pt_resolution_scale = 1.0;
    } else if (strEql(name, "high")) {
        pt_samples = 48;
        pt_bounces = 6;
        pt_resolution_scale = 1.0;
    } else if (strEql(name, "ultra")) {
        pt_samples = 256;
        pt_bounces = 10;
        pt_resolution_scale = 1.0;
    } else return error.InvalidArguments;
    ctx.layer.renderer.resetPathTraceState();
    try ctx.reply(.{});
}

pub fn setRenderOutput(ctx: *Ctx) !void {
    if (try ctx.paramOpt([]const u8, "preset")) |p| {
        if (strEql(p, "viewport")) render_output_preset = .viewport else if (strEql(p, "720p")) {
            render_output_preset = .custom;
            render_output_width = 1280;
            render_output_height = 720;
        } else if (strEql(p, "1080p") or strEql(p, "hd_1080")) render_output_preset = .hd_1080 else if (strEql(p, "1440p") or strEql(p, "dci_2k")) render_output_preset = .dci_2k else if (strEql(p, "4k") or strEql(p, "uhd_4k")) render_output_preset = .uhd_4k else if (strEql(p, "custom")) render_output_preset = .custom else return error.InvalidArguments;
    }
    if (try ctx.paramOpt(u64, "width")) |v| {
        render_output_width = @intCast(std.math.clamp(v, 64, 8192));
    }
    if (try ctx.paramOpt(u64, "height")) |v| {
        render_output_height = @intCast(std.math.clamp(v, 64, 8192));
    }
    if (try ctx.paramOpt([]const u8, "format")) |f| {
        if (strEql(f, "png")) render_output_format = .png else if (strEql(f, "exr")) render_output_format = .exr else if (strEql(f, "jpg")) render_output_format = .jpg else return error.InvalidArguments;
    }
    if (try ctx.paramOpt([]const u8, "path")) |p| {
        const len = @min(p.len, render_output_path.len);
        @memcpy(render_output_path[0..len], p[0..len]);
        render_output_path_len = len;
    }
    try ctx.reply(.{});
}

fn resolveOutputDimensions(vp_size: [2]u32) [2]u32 {
    return switch (render_output_preset) {
        .viewport => vp_size,
        .hd_1080 => .{ 1920, 1080 },
        .dci_2k => .{ 2048, 1080 },
        .uhd_4k => .{ 3840, 2160 },
        .custom => .{ @max(render_output_width, 64), @max(render_output_height, 64) },
    };
}

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
