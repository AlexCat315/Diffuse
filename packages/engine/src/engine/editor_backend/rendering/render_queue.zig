const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");

const cinematic = engine.cinematic;
const ffmpeg_encode = cinematic.ffmpeg_encode;

// ---------------------------------------------------------------------------
// Render Queue data model
// ---------------------------------------------------------------------------

pub const RenderJobStatus = @import("guava").editor_rpc.schema.types.RenderJobStatus;

pub const RenderJobConfig = struct {
    sequence_path: [256]u8 = [_]u8{0} ** 256,
    output_dir: [256]u8 = [_]u8{0} ** 256,
    width: u32 = 1920,
    height: u32 = 1080,
    format: state_mod.RenderOutputFormat = .png,
    samples: u32 = 256,
    bounces: u32 = 8,
    use_path_trace: bool = true,
    encode_video: bool = false,
    video_codec: state_mod.VideoCodec = .h264,
};

pub const RenderJob = struct {
    config: RenderJobConfig = .{},
    status: RenderJobStatus = .queued,
    total_frames: u32 = 0,
    current_frame: u32 = 0,
    status_message: [256]u8 = [_]u8{0} ** 256,
};

pub const RenderQueueState = struct {
    jobs: std.ArrayListUnmanaged(RenderJob) = .empty,
    is_running: bool = false,
    current_job_index: u32 = 0,
    new_job: RenderJobConfig = .{},

    pub fn deinit(self: *RenderQueueState, allocator: std.mem.Allocator) void {
        self.jobs.deinit(allocator);
    }
};

pub fn tickRenderQueue(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    rq_state: *RenderQueueState,
) !void {
    if (!rq_state.is_running) return;
    if (rq_state.current_job_index >= rq_state.jobs.items.len) {
        rq_state.is_running = false;
        return;
    }

    const job = &rq_state.jobs.items[rq_state.current_job_index];

    switch (job.status) {
        .queued => {
            const seq_path = std.mem.sliceTo(job.config.sequence_path[0..], 0);
            if (seq_path.len == 0) {
                job.status = .failed;
                const msg = "No sequence path specified";
                @memset(job.status_message[0..], 0);
                @memcpy(job.status_message[0..msg.len], msg);
                advanceToNextJob(rq_state);
                return;
            }

            state.render_output_use_cinematic_sequence = true;
            @memcpy(state.render_output_cinematic_sequence_path[0..seq_path.len], seq_path);
            if (seq_path.len < 256) @memset(state.render_output_cinematic_sequence_path[seq_path.len..], 0);

            state.render_output_width = job.config.width;
            state.render_output_height = job.config.height;
            state.render_output_format = job.config.format;
            state.render_output_samples = job.config.samples;
            state.render_output_bounces = job.config.bounces;
            state.render_output_encode_video = job.config.encode_video;
            state.render_output_video_codec = job.config.video_codec;

            const out_dir = std.mem.sliceTo(job.config.output_dir[0..], 0);
            @memset(state.render_output_path_buffer[0..], 0);
            const copy_len = @min(out_dir.len, state.render_output_path_buffer.len - 1);
            @memcpy(state.render_output_path_buffer[0..copy_len], out_dir[0..copy_len]);

            state.render_output_sequence_enabled = true;
            if (job.config.use_path_trace) {
                state.viewport_pipeline_mode = .path_trace;
            }

            const allocator = state.allocator orelse layer_context.world.allocator;
            var seq = cinematic.loadFromPath(allocator, seq_path) catch |err| {
                job.status = .failed;
                const err_name = @errorName(err);
                @memset(job.status_message[0..], 0);
                const prefix = "Failed to load: ";
                @memcpy(job.status_message[0..prefix.len], prefix);
                const elen = @min(err_name.len, 256 - prefix.len);
                @memcpy(job.status_message[prefix.len..][0..elen], err_name[0..elen]);
                advanceToNextJob(rq_state);
                return;
            };
            const fps = @max(seq.fps, 1.0);
            const total: u32 = @max(@as(u32, @intFromFloat(@ceil(seq.duration * fps))), 1);
            seq.deinit();

            job.total_frames = total;
            job.current_frame = 0;
            state.render_output_sequence_frame_count = total;
            state.render_output_sequence_fps = @intFromFloat(fps);

            job.status = .rendering;
            {
                const msg = "Starting render...";
                @memset(job.status_message[0..], 0);
                @memcpy(job.status_message[0..msg.len], msg);
            }

            state.render_output_job_stage = .resize_and_render;
            state.render_output_job_is_sequence = true;
            state.render_output_job_total_frames = total;
            state.render_output_job_frame_index = 0;
        },
        .rendering => {
            job.current_frame = state.render_output_job_frame_index;

            if (state.render_output_job_stage == .idle and state.render_output_status == .success) {
                job.current_frame = job.total_frames;
                state.render_output_use_cinematic_sequence = false;

                if (job.config.encode_video) {
                    const allocator = state.allocator orelse layer_context.world.allocator;
                    const out_dir = std.mem.sliceTo(job.config.output_dir[0..], 0);
                    const format_ext: []const u8 = switch (job.config.format) {
                        .png => ".png",
                        .exr => ".exr",
                    };
                    const input_pattern = ffmpeg_encode.detectInputPattern(allocator, out_dir, format_ext) catch {
                        setJobStatus(job, .complete, "Render complete (video encode skipped: path error)");
                        advanceToNextJob(rq_state);
                        return;
                    };
                    defer allocator.free(input_pattern);
                    const codec: ffmpeg_encode.VideoCodec = @enumFromInt(@intFromEnum(job.config.video_codec));
                    const video_path = ffmpeg_encode.resolveVideoOutputPath(allocator, out_dir, codec) catch {
                        setJobStatus(job, .complete, "Render complete (video encode skipped: path error)");
                        advanceToNextJob(rq_state);
                        return;
                    };
                    defer allocator.free(video_path);

                    setJobStatus(job, .rendering, "Encoding video...");

                    var result = ffmpeg_encode.encode(allocator, .{
                        .input_pattern = input_pattern,
                        .output_path = video_path,
                        .fps = state.render_output_sequence_fps,
                        .codec = codec,
                        .width = job.config.width,
                        .height = job.config.height,
                    }) catch {
                        setJobStatus(job, .complete, "Render complete (ffmpeg not found or failed to start)");
                        advanceToNextJob(rq_state);
                        return;
                    };
                    defer result.deinit();

                    if (result.success) {
                        setJobStatus(job, .complete, "Render + video encode complete");
                    } else {
                        setJobStatus(job, .complete, "Render complete (video encode failed)");
                    }
                } else {
                    setJobStatus(job, .complete, "Render complete");
                }
                advanceToNextJob(rq_state);
            } else if (state.render_output_job_stage == .idle and state.render_output_status == .failure) {
                job.status = .failed;
                const status_text = state.renderOutputStatusText();
                @memset(job.status_message[0..], 0);
                const mlen = @min(status_text.len, 255);
                @memcpy(job.status_message[0..mlen], status_text[0..mlen]);
                state.render_output_use_cinematic_sequence = false;
                advanceToNextJob(rq_state);
            }
        },
        .complete, .failed => {
            advanceToNextJob(rq_state);
        },
    }
}

fn setJobStatus(job: *RenderJob, new_status: RenderJobStatus, msg: []const u8) void {
    job.status = new_status;
    @memset(job.status_message[0..], 0);
    const len = @min(msg.len, job.status_message.len);
    @memcpy(job.status_message[0..len], msg[0..len]);
}

fn advanceToNextJob(rq_state: *RenderQueueState) void {
    rq_state.current_job_index += 1;
    while (rq_state.current_job_index < rq_state.jobs.items.len) {
        if (rq_state.jobs.items[rq_state.current_job_index].status == .queued) return;
        rq_state.current_job_index += 1;
    }
    rq_state.is_running = false;
}
