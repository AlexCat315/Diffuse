//! FFmpeg video encoding — spawns an external `ffmpeg` process to encode
//! a rendered image sequence into a video file (H.264, H.265, or ProRes).

const std = @import("std");
const io_globals = @import("io_globals");

pub const VideoCodec = enum {
    h264,
    h265,
    prores,
};

pub const EncodeOptions = struct {
    /// Input pattern, e.g. "output/frame_%04d.png"
    input_pattern: []const u8,
    /// Output video file path, e.g. "output/render.mp4"
    output_path: []const u8,
    fps: u32 = 24,
    codec: VideoCodec = .h264,
    /// CRF quality for H.264/H.265 (lower = better, 0-51). Ignored for ProRes.
    crf: u32 = 18,
    width: u32 = 1920,
    height: u32 = 1080,
};

pub const EncodeResult = struct {
    success: bool,
    exit_code: u32,
    stderr_output: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncodeResult) void {
        self.allocator.free(self.stderr_output);
    }
};

/// Build the ffmpeg command arguments for the given options.
/// Returns an owned argv slice; caller frees with allocator.
pub fn buildFfmpegArgs(allocator: std.mem.Allocator, options: EncodeOptions) ![]const []const u8 {
    var args = std.ArrayList([]const u8).empty;
    errdefer {
        for (args.items) |a| allocator.free(a);
        args.deinit(allocator);
    }

    try args.append(allocator, try allocator.dupe(u8, "ffmpeg"));
    try args.append(allocator, try allocator.dupe(u8, "-y")); // overwrite

    // Input framerate
    try args.append(allocator, try allocator.dupe(u8, "-framerate"));
    try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{options.fps}));

    // Input pattern
    try args.append(allocator, try allocator.dupe(u8, "-i"));
    try args.append(allocator, try allocator.dupe(u8, options.input_pattern));

    // Video filter: scale to target resolution (pad if needed)
    try args.append(allocator, try allocator.dupe(u8, "-vf"));
    try args.append(allocator, try std.fmt.allocPrint(
        allocator,
        "scale={d}:{d}:flags=lanczos",
        .{ options.width, options.height },
    ));

    // Codec-specific options
    switch (options.codec) {
        .h264 => {
            try args.append(allocator, try allocator.dupe(u8, "-c:v"));
            try args.append(allocator, try allocator.dupe(u8, "libx264"));
            try args.append(allocator, try allocator.dupe(u8, "-crf"));
            try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{options.crf}));
            try args.append(allocator, try allocator.dupe(u8, "-pix_fmt"));
            try args.append(allocator, try allocator.dupe(u8, "yuv420p"));
        },
        .h265 => {
            try args.append(allocator, try allocator.dupe(u8, "-c:v"));
            try args.append(allocator, try allocator.dupe(u8, "libx265"));
            try args.append(allocator, try allocator.dupe(u8, "-crf"));
            try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{options.crf}));
            try args.append(allocator, try allocator.dupe(u8, "-pix_fmt"));
            try args.append(allocator, try allocator.dupe(u8, "yuv420p"));
        },
        .prores => {
            try args.append(allocator, try allocator.dupe(u8, "-c:v"));
            try args.append(allocator, try allocator.dupe(u8, "prores_ks"));
            try args.append(allocator, try allocator.dupe(u8, "-profile:v"));
            try args.append(allocator, try allocator.dupe(u8, "3")); // ProRes 422 HQ
            try args.append(allocator, try allocator.dupe(u8, "-pix_fmt"));
            try args.append(allocator, try allocator.dupe(u8, "yuv422p10le"));
        },
    }

    // Output
    try args.append(allocator, try allocator.dupe(u8, options.output_path));

    return args.toOwnedSlice(allocator);
}

pub fn freeFfmpegArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |a| allocator.free(a);
    allocator.free(args);
}

/// Detect the ffmpeg input pattern from an output directory and format.
/// Scans for files matching the pattern `frame_NNNN.<ext>` and builds
/// the appropriate ffmpeg glob/sequence input pattern.
pub fn detectInputPattern(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    extension: []const u8,
) ![]u8 {
    // Standard pattern: <dir>/frame_%04d.<ext>
    return std.fmt.allocPrint(allocator, "{s}/frame_%04d{s}", .{ output_dir, extension });
}

/// Resolve the output video file path from the output directory and codec.
pub fn resolveVideoOutputPath(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    codec: VideoCodec,
) ![]u8 {
    const ext: []const u8 = switch (codec) {
        .h264 => ".mp4",
        .h265 => ".mp4",
        .prores => ".mov",
    };
    return std.fmt.allocPrint(allocator, "{s}/render{s}", .{ output_dir, ext });
}

/// Run ffmpeg synchronously. Returns an EncodeResult the caller must deinit.
pub fn encode(allocator: std.mem.Allocator, options: EncodeOptions) !EncodeResult {
    const argv = try buildFfmpegArgs(allocator, options);
    defer freeFfmpegArgs(allocator, argv);

    const result = try std.process.run(allocator, io_globals.global_io, .{
        .argv = argv,
        .stdout_limit = .limited(0),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);

    const exit_code: u32 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };

    return .{
        .success = exit_code == 0,
        .exit_code = exit_code,
        .stderr_output = result.stderr,
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildFfmpegArgs produces valid argv for h264" {
    const allocator = std.testing.allocator;
    const args = try buildFfmpegArgs(allocator, .{
        .input_pattern = "out/frame_%04d.png",
        .output_path = "out/render.mp4",
        .fps = 30,
        .codec = .h264,
        .crf = 20,
        .width = 1920,
        .height = 1080,
    });
    defer freeFfmpegArgs(allocator, args);

    // Verify first arg is ffmpeg
    try std.testing.expectEqualStrings("ffmpeg", args[0]);
    // Verify "-y" is present
    try std.testing.expectEqualStrings("-y", args[1]);
    // Last arg is the output path
    try std.testing.expectEqualStrings("out/render.mp4", args[args.len - 1]);
    // Should contain "libx264"
    var found_codec = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "libx264")) found_codec = true;
    }
    try std.testing.expect(found_codec);
}

test "buildFfmpegArgs produces valid argv for prores" {
    const allocator = std.testing.allocator;
    const args = try buildFfmpegArgs(allocator, .{
        .input_pattern = "out/frame_%04d.exr",
        .output_path = "out/render.mov",
        .fps = 24,
        .codec = .prores,
        .width = 2048,
        .height = 1080,
    });
    defer freeFfmpegArgs(allocator, args);

    var found_prores = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "prores_ks")) found_prores = true;
    }
    try std.testing.expect(found_prores);
    try std.testing.expectEqualStrings("out/render.mov", args[args.len - 1]);
}

test "resolveVideoOutputPath" {
    const allocator = std.testing.allocator;
    const mp4 = try resolveVideoOutputPath(allocator, "/tmp/renders", .h264);
    defer allocator.free(mp4);
    try std.testing.expectEqualStrings("/tmp/renders/render.mp4", mp4);

    const mov = try resolveVideoOutputPath(allocator, "/tmp/renders", .prores);
    defer allocator.free(mov);
    try std.testing.expectEqualStrings("/tmp/renders/render.mov", mov);
}
