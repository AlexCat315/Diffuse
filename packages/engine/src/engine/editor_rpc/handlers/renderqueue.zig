///! handlers/renderqueue.zig — batch render job queue management.
///!
///! Manages a queue of render jobs. Each job pairs a cinematic sequence
///! path with render configuration (resolution, format, path tracing, etc.).
///! Job state is kept in process-lifetime statics, similar to camera bookmarks.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

// ── Job storage (process-lifetime) ──────────────────────────────

const RenderJobStatus = enum {
    queued,
    rendering,
    complete,
    failed,
};

const RenderJob = struct {
    sequence_path: [256]u8 = [_]u8{0} ** 256,
    output_dir: [256]u8 = [_]u8{0} ** 256,
    width: u32 = 1920,
    height: u32 = 1080,
    format: [8]u8 = [_]u8{0} ** 8, // "png" or "exr"
    format_len: usize = 0,
    samples: u32 = 256,
    bounces: u32 = 8,
    use_path_trace: bool = true,
    encode_video: bool = false,
    video_codec: [8]u8 = [_]u8{0} ** 8, // "h264", "h265", "prores"
    codec_len: usize = 0,
    status: RenderJobStatus = .queued,
    total_frames: u32 = 0,
    current_frame: u32 = 0,
    status_message: [256]u8 = [_]u8{0} ** 256,
    msg_len: usize = 0,

    fn seqPath(self: *const RenderJob) []const u8 {
        return std.mem.sliceTo(self.sequence_path[0..], 0);
    }
    fn outDir(self: *const RenderJob) []const u8 {
        return std.mem.sliceTo(self.output_dir[0..], 0);
    }
    fn formatStr(self: *const RenderJob) []const u8 {
        return self.format[0..self.format_len];
    }
    fn codecStr(self: *const RenderJob) []const u8 {
        return self.video_codec[0..self.codec_len];
    }
    fn statusMsg(self: *const RenderJob) []const u8 {
        return self.status_message[0..self.msg_len];
    }
};

const max_jobs = 32;
var job_buf: [max_jobs]RenderJob = undefined;
var job_len: usize = 0;
var queue_running: bool = false;

// ── RPC handlers ────────────────────────────────────────────────

pub fn listJobs(ctx: *Ctx) !void {
    const JobInfo = struct {
        index: u64,
        sequencePath: []const u8,
        outputDir: []const u8,
        width: u32,
        height: u32,
        format: []const u8,
        samples: u32,
        bounces: u32,
        usePathTrace: bool,
        encodeVideo: bool,
        videoCodec: []const u8,
        status: []const u8,
        totalFrames: u32,
        currentFrame: u32,
        statusMessage: []const u8,
    };

    var list = std.ArrayList(JobInfo).empty;
    defer list.deinit(ctx.allocator);

    for (job_buf[0..job_len], 0..) |*job, i| {
        try list.append(ctx.allocator, .{
            .index = @intCast(i),
            .sequencePath = job.seqPath(),
            .outputDir = job.outDir(),
            .width = job.width,
            .height = job.height,
            .format = job.formatStr(),
            .samples = job.samples,
            .bounces = job.bounces,
            .usePathTrace = job.use_path_trace,
            .encodeVideo = job.encode_video,
            .videoCodec = job.codecStr(),
            .status = @tagName(job.status),
            .totalFrames = job.total_frames,
            .currentFrame = job.current_frame,
            .statusMessage = job.statusMsg(),
        });
    }

    try ctx.reply(.{ .jobs = list.items, .isRunning = queue_running });
}

pub fn addJob(ctx: *Ctx) !void {
    if (job_len >= max_jobs) return error.OutOfMemory;

    const seq_path = try ctx.param([]const u8, "sequencePath");
    const output_dir = (try ctx.paramOpt([]const u8, "outputDir")) orelse "render_output";
    const width: u32 = @intCast((try ctx.paramOpt(u64, "width")) orelse 1920);
    const height: u32 = @intCast((try ctx.paramOpt(u64, "height")) orelse 1080);
    const format = (try ctx.paramOpt([]const u8, "format")) orelse "png";
    const samples: u32 = @intCast((try ctx.paramOpt(u64, "samples")) orelse 256);
    const bounces: u32 = @intCast((try ctx.paramOpt(u64, "bounces")) orelse 8);
    const use_path_trace = (try ctx.paramOpt(bool, "usePathTrace")) orelse true;
    const encode_video = (try ctx.paramOpt(bool, "encodeVideo")) orelse false;
    const video_codec = (try ctx.paramOpt([]const u8, "videoCodec")) orelse "h264";

    var job = RenderJob{
        .width = width,
        .height = height,
        .samples = samples,
        .bounces = bounces,
        .use_path_trace = use_path_trace,
        .encode_video = encode_video,
    };

    // Copy paths
    const sp_len = @min(seq_path.len, 255);
    @memcpy(job.sequence_path[0..sp_len], seq_path[0..sp_len]);
    const od_len = @min(output_dir.len, 255);
    @memcpy(job.output_dir[0..od_len], output_dir[0..od_len]);
    job.format_len = @min(format.len, 7);
    @memcpy(job.format[0..job.format_len], format[0..job.format_len]);
    job.codec_len = @min(video_codec.len, 7);
    @memcpy(job.video_codec[0..job.codec_len], video_codec[0..job.codec_len]);

    job_buf[job_len] = job;
    job_len += 1;
    try ctx.reply(.{ .index = @as(u64, @intCast(job_len - 1)) });
}

pub fn removeJob(ctx: *Ctx) !void {
    const idx: usize = @intCast(try ctx.param(u64, "index"));
    if (idx >= job_len) return error.InvalidArguments;
    if (job_buf[idx].status == .rendering) return error.InvalidArguments;

    if (idx + 1 < job_len) {
        std.mem.copyForwards(RenderJob, job_buf[idx .. job_len - 1], job_buf[idx + 1 .. job_len]);
    }
    job_len -= 1;
    try ctx.reply(.{});
}

pub fn startQueue(ctx: *Ctx) !void {
    if (queue_running) return error.InvalidArguments;
    var has_queued = false;
    for (job_buf[0..job_len]) |job| {
        if (job.status == .queued) {
            has_queued = true;
            break;
        }
    }
    if (!has_queued) return error.InvalidArguments;
    queue_running = true;
    // Mark the first queued job as rendering
    for (job_buf[0..job_len]) |*job| {
        if (job.status == .queued) {
            job.status = .rendering;
            const msg = "Starting render...";
            @memcpy(job.status_message[0..msg.len], msg);
            job.msg_len = msg.len;
            break;
        }
    }
    try ctx.reply(.{});
}

pub fn cancelQueue(ctx: *Ctx) !void {
    if (!queue_running) return error.InvalidArguments;
    queue_running = false;
    for (job_buf[0..job_len]) |*job| {
        if (job.status == .rendering) {
            job.status = .failed;
            const msg = "Cancelled by user";
            @memset(job.status_message[0..], 0);
            @memcpy(job.status_message[0..msg.len], msg);
            job.msg_len = msg.len;
        }
    }
    try ctx.reply(.{});
}

pub fn clearCompleted(ctx: *Ctx) !void {
    var i: usize = 0;
    while (i < job_len) {
        if (job_buf[i].status == .complete or job_buf[i].status == .failed) {
            if (i + 1 < job_len) {
                std.mem.copyForwards(RenderJob, job_buf[i .. job_len - 1], job_buf[i + 1 .. job_len]);
            }
            job_len -= 1;
        } else {
            i += 1;
        }
    }
    try ctx.reply(.{});
}
