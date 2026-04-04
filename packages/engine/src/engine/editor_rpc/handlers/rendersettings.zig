///! handlers/rendersettings.zig — viewport render settings.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const EditorSettings = @import("../settings.zig").EditorSettings;
const ResolutionPreset = EditorSettings.ResolutionPreset;

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
    const vp = &ctx.settings.viewport;
    const ro = &vp.render_output;
    const vp_size = ctx.layer.renderer.sceneViewportSize();
    const dims = resolveOutputDimensions(ro, vp_size);
    try ctx.reply(.{
        .shadingMode = @tagName(vp.shading_mode),
        .transformSpace = @tagName(vp.transform_space),
        .showGrid = vp.show_grid,
        .showBones = vp.show_bones,
        .showCollision = vp.show_collision,
        .pathTrace = .{
            .samples = vp.pt_samples,
            .bounces = vp.pt_bounces,
            .resolutionScale = vp.pt_resolution_scale,
        },
        .viewportSize = .{ .width = vp_size[0], .height = vp_size[1] },
        .renderOutput = .{
            .preset = presetDisplayName(ro.preset),
            .width = dims[0],
            .height = dims[1],
            .format = @tagName(ro.format),
            .path = ro.path[0..ro.path_len],
        },
    });
}

pub fn setShadingMode(ctx: *Ctx) !void {
    const mode_str = try ctx.param([]const u8, "mode");
    const vp = &ctx.settings.viewport;
    if (strEql(mode_str, "solid")) {
        vp.shading_mode = .solid;
    } else if (strEql(mode_str, "material")) {
        vp.shading_mode = .material;
    } else if (strEql(mode_str, "rendered")) {
        vp.shading_mode = .rendered;
    } else if (strEql(mode_str, "wireframe")) {
        vp.shading_mode = .wireframe;
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

pub fn setTransformSpace(ctx: *Ctx) !void {
    const space_str = try ctx.param([]const u8, "space");
    const vp = &ctx.settings.viewport;
    if (strEql(space_str, "local")) {
        vp.transform_space = .local;
    } else if (strEql(space_str, "world")) {
        vp.transform_space = .world;
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

pub fn setOverlay(ctx: *Ctx) !void {
    const key = try ctx.param([]const u8, "key");
    const val = try ctx.param(bool, "value");
    const vp = &ctx.settings.viewport;
    if (strEql(key, "showGrid")) {
        vp.show_grid = val;
    } else if (strEql(key, "showBones")) {
        vp.show_bones = val;
    } else if (strEql(key, "showCollision")) {
        vp.show_collision = val;
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

pub fn setPathTrace(ctx: *Ctx) !void {
    const vp = &ctx.settings.viewport;
    if (try ctx.paramOpt(u64, "samples")) |v| {
        vp.pt_samples = @intCast(std.math.clamp(v, 1, 4096));
    }
    if (try ctx.paramOpt(u64, "bounces")) |v| {
        vp.pt_bounces = @intCast(std.math.clamp(v, 1, 12));
    }
    if (try ctx.paramOpt(f32, "resolutionScale")) |v| {
        vp.pt_resolution_scale = std.math.clamp(v, 0.25, 1.0);
    }
    ctx.layer.renderer.resetPathTraceState();
    try ctx.reply(.{});
}

pub fn applyPtPreset(ctx: *Ctx) !void {
    const name = try ctx.param([]const u8, "preset");
    const vp = &ctx.settings.viewport;
    if (strEql(name, "preview")) {
        vp.pt_samples = 1;
        vp.pt_bounces = 1;
        vp.pt_resolution_scale = 0.5;
    } else if (strEql(name, "low")) {
        vp.pt_samples = 4;
        vp.pt_bounces = 2;
        vp.pt_resolution_scale = 0.75;
    } else if (strEql(name, "medium")) {
        vp.pt_samples = 12;
        vp.pt_bounces = 4;
        vp.pt_resolution_scale = 1.0;
    } else if (strEql(name, "high")) {
        vp.pt_samples = 48;
        vp.pt_bounces = 6;
        vp.pt_resolution_scale = 1.0;
    } else if (strEql(name, "ultra")) {
        vp.pt_samples = 256;
        vp.pt_bounces = 10;
        vp.pt_resolution_scale = 1.0;
    } else return error.InvalidArguments;
    ctx.layer.renderer.resetPathTraceState();
    try ctx.reply(.{});
}

pub fn setRenderOutput(ctx: *Ctx) !void {
    const ro = &ctx.settings.viewport.render_output;
    if (try ctx.paramOpt([]const u8, "preset")) |p| {
        if (strEql(p, "viewport")) ro.preset = .viewport else if (strEql(p, "720p")) {
            ro.preset = .custom;
            ro.width = 1280;
            ro.height = 720;
        } else if (strEql(p, "1080p") or strEql(p, "hd_1080")) ro.preset = .hd_1080 else if (strEql(p, "1440p") or strEql(p, "dci_2k")) ro.preset = .dci_2k else if (strEql(p, "4k") or strEql(p, "uhd_4k")) ro.preset = .uhd_4k else if (strEql(p, "custom")) ro.preset = .custom else return error.InvalidArguments;
    }
    if (try ctx.paramOpt(u64, "width")) |v| {
        ro.width = @intCast(std.math.clamp(v, 64, 8192));
    }
    if (try ctx.paramOpt(u64, "height")) |v| {
        ro.height = @intCast(std.math.clamp(v, 64, 8192));
    }
    if (try ctx.paramOpt([]const u8, "format")) |f| {
        if (strEql(f, "png")) ro.format = .png else if (strEql(f, "exr")) ro.format = .exr else if (strEql(f, "jpg")) ro.format = .jpg else return error.InvalidArguments;
    }
    if (try ctx.paramOpt([]const u8, "path")) |p| {
        const len = @min(p.len, ro.path.len);
        @memcpy(ro.path[0..len], p[0..len]);
        ro.path_len = len;
    }
    try ctx.reply(.{});
}

fn resolveOutputDimensions(ro: *const EditorSettings.RenderOutput, vp_size: [2]u32) [2]u32 {
    return switch (ro.preset) {
        .viewport => vp_size,
        .hd_1080 => .{ 1920, 1080 },
        .dci_2k => .{ 2048, 1080 },
        .uhd_4k => .{ 3840, 2160 },
        .custom => .{ @max(ro.width, 64), @max(ro.height, 64) },
    };
}

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
