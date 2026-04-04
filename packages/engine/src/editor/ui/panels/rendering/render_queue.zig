//! Render Queue panel — batch offline rendering of cinematic sequences.
//!
//! Provides a UI to queue multiple render jobs (each pairing a Sequence file
//! with a render configuration), monitor progress, and optionally encode
//! results to video via FFmpeg.

const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const state_mod = @import("../../../core/state.zig");
const layout = @import("../../layout.zig");
const theme = @import("../../theme.zig");

const cinematic = engine.cinematic;
const ffmpeg_encode = cinematic.ffmpeg_encode;

// ---------------------------------------------------------------------------
// Render Queue data model
// ---------------------------------------------------------------------------

pub const RenderJobStatus = enum {
    queued,
    rendering,
    complete,
    failed,
};

pub const RenderJobConfig = struct {
    /// Path to the .guava_sequence file.
    sequence_path: [256]u8 = [_]u8{0} ** 256,
    /// Output directory for rendered frames.
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
    // Add-job form
    new_job: RenderJobConfig = .{},

    pub fn deinit(self: *RenderQueueState, allocator: std.mem.Allocator) void {
        self.jobs.deinit(allocator);
    }
};

// ---------------------------------------------------------------------------
// Panel state management
// ---------------------------------------------------------------------------

pub fn createRenderQueueState() RenderQueueState {
    return .{};
}

// ---------------------------------------------------------------------------
// Panel drawing
// ---------------------------------------------------------------------------

pub fn drawRenderQueueWindow(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    rq_state: *RenderQueueState,
) !void {
    const label = state.text(.render_queue);
    var open = state.render_queue_open;
    if (!gui.beginWindowOpen(label, &open)) {
        state.render_queue_open = open;
        gui.endWindow();
        return;
    }
    defer gui.endWindow();
    state.render_queue_open = open;

    const allocator = state.allocator orelse layer_context.world.allocator;

    // ---- Add Job Section ----
    gui.separatorText("Add Render Job");

    gui.text("Sequence File:");
    gui.setNextItemWidth(-1.0);
    _ = gui.inputText("##rq_seq_path", rq_state.new_job.sequence_path[0..]);

    gui.text("Output Directory:");
    gui.setNextItemWidth(-1.0);
    _ = gui.inputText("##rq_output_dir", rq_state.new_job.output_dir[0..]);

    // Resolution
    {
        var w: i32 = @intCast(rq_state.new_job.width);
        var h: i32 = @intCast(rq_state.new_job.height);
        gui.setNextItemWidth(120.0);
        if (gui.dragInt("Width##rq_w", &w, 1.0, 64, 7680)) {
            rq_state.new_job.width = @intCast(std.math.clamp(w, 64, 7680));
        }
        gui.sameLine();
        gui.setNextItemWidth(120.0);
        if (gui.dragInt("Height##rq_h", &h, 1.0, 64, 4320)) {
            rq_state.new_job.height = @intCast(std.math.clamp(h, 64, 4320));
        }
    }

    // Format
    {
        const format_label: []const u8 = switch (rq_state.new_job.format) {
            .png => "PNG",
            .exr => "OpenEXR",
        };
        if (gui.beginCombo("Format##rq_format", format_label)) {
            if (gui.selectable("PNG", rq_state.new_job.format == .png, false, 0.0, 0.0)) {
                rq_state.new_job.format = .png;
            }
            if (gui.selectable("OpenEXR", rq_state.new_job.format == .exr, false, 0.0, 0.0)) {
                rq_state.new_job.format = .exr;
            }
            gui.endCombo();
        }
    }

    // Path trace config
    _ = gui.checkbox("Path Trace##rq_pt", &rq_state.new_job.use_path_trace);
    if (rq_state.new_job.use_path_trace) {
        var samples: i32 = @intCast(rq_state.new_job.samples);
        gui.setNextItemWidth(120.0);
        if (gui.dragInt("Samples##rq_samples", &samples, 1.0, 1, 4096)) {
            rq_state.new_job.samples = @intCast(std.math.clamp(samples, 1, 4096));
        }
        var bounces: i32 = @intCast(rq_state.new_job.bounces);
        gui.setNextItemWidth(120.0);
        if (gui.dragInt("Bounces##rq_bounces", &bounces, 1.0, 1, 12)) {
            rq_state.new_job.bounces = @intCast(std.math.clamp(bounces, 1, 12));
        }
    }

    // Video encode
    _ = gui.checkbox("Encode Video##rq_encode", &rq_state.new_job.encode_video);
    if (rq_state.new_job.encode_video) {
        const codec_label: []const u8 = switch (rq_state.new_job.video_codec) {
            .h264 => "H.264",
            .h265 => "H.265",
            .prores => "ProRes",
        };
        if (gui.beginCombo("Codec##rq_codec", codec_label)) {
            if (gui.selectable("H.264", rq_state.new_job.video_codec == .h264, false, 0.0, 0.0)) {
                rq_state.new_job.video_codec = .h264;
            }
            if (gui.selectable("H.265", rq_state.new_job.video_codec == .h265, false, 0.0, 0.0)) {
                rq_state.new_job.video_codec = .h265;
            }
            if (gui.selectable("ProRes", rq_state.new_job.video_codec == .prores, false, 0.0, 0.0)) {
                rq_state.new_job.video_codec = .prores;
            }
            gui.endCombo();
        }
    }

    if (gui.buttonEx("Add to Queue", 140.0, 0.0)) {
        const seq_path = std.mem.sliceTo(rq_state.new_job.sequence_path[0..], 0);
        if (seq_path.len > 0) {
            try rq_state.jobs.append(allocator, .{
                .config = rq_state.new_job,
                .status = .queued,
            });
        }
    }

    gui.separator();

    // ---- Job Queue ----
    gui.separatorText("Render Queue");

    if (rq_state.jobs.items.len == 0) {
        gui.textWrapped("No jobs in queue. Add a job above to get started.");
    } else {
        for (rq_state.jobs.items, 0..) |*job, i| {
            const seq_name = std.mem.sliceTo(job.config.sequence_path[0..], 0);
            var header_buf: [320]u8 = undefined;
            const status_str: []const u8 = switch (job.status) {
                .queued => "[Queued]",
                .rendering => "[Rendering]",
                .complete => "[Complete]",
                .failed => "[Failed]",
            };
            const header = std.fmt.bufPrint(&header_buf, "{s} {s}##rq_job_{d}", .{ status_str, seq_name, i }) catch continue;
            if (gui.collapsingHeader(header, false)) {
                const out_dir = std.mem.sliceTo(job.config.output_dir[0..], 0);
                gui.text(out_dir);
                var dim_buf: [64]u8 = undefined;
                const dim_text = std.fmt.bufPrint(&dim_buf, "{d} x {d}", .{ job.config.width, job.config.height }) catch "?";
                gui.labelText("Resolution", dim_text);
                var frame_buf: [64]u8 = undefined;
                const frame_text = std.fmt.bufPrint(&frame_buf, "{d} / {d}", .{ job.current_frame, job.total_frames }) catch "?";
                gui.labelText("Progress", frame_text);
                const msg = std.mem.sliceTo(job.status_message[0..], 0);
                if (msg.len > 0) {
                    gui.textWrapped(msg);
                }

                if (job.status == .queued and !rq_state.is_running) {
                    var remove_buf: [32]u8 = undefined;
                    const remove_label = std.fmt.bufPrint(&remove_buf, "Remove##rq_rm_{d}", .{i}) catch "Remove";
                    if (gui.buttonEx(remove_label, 80.0, 0.0)) {
                        _ = rq_state.jobs.orderedRemove(i);
                        break; // list changed, stop iteration
                    }
                }
            }
        }
    }

    gui.separator();

    // ---- Queue Controls ----
    if (rq_state.is_running) {
        gui.textWrapped("Render queue is running...");
        if (gui.buttonEx("Cancel", 100.0, 0.0)) {
            rq_state.is_running = false;
            // Mark current rendering job as failed
            if (rq_state.current_job_index < rq_state.jobs.items.len) {
                const job = &rq_state.jobs.items[rq_state.current_job_index];
                if (job.status == .rendering) {
                    job.status = .failed;
                    const fail_msg = "Cancelled by user";
                    @memset(job.status_message[0..], 0);
                    @memcpy(job.status_message[0..fail_msg.len], fail_msg);
                }
            }
        }
    } else {
        var has_queued = false;
        for (rq_state.jobs.items) |job| {
            if (job.status == .queued) {
                has_queued = true;
                break;
            }
        }
        if (has_queued) {
            if (gui.buttonEx("Start Queue", 120.0, 0.0)) {
                rq_state.is_running = true;
                // Find the first queued job
                for (rq_state.jobs.items, 0..) |job, i| {
                    if (job.status == .queued) {
                        rq_state.current_job_index = @intCast(i);
                        break;
                    }
                }
            }
            gui.sameLine();
        }
        if (gui.buttonEx("Clear Completed", 130.0, 0.0)) {
            // Remove completed/failed jobs
            var i: usize = 0;
            while (i < rq_state.jobs.items.len) {
                if (rq_state.jobs.items[i].status == .complete or rq_state.jobs.items[i].status == .failed) {
                    _ = rq_state.jobs.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Queue tick — called each frame while the queue is running.
// Drives the current job forward by integrating with the existing
// render output state machine.
// ---------------------------------------------------------------------------

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
            // Initialize the job: load sequence and compute frame count
            const seq_path = std.mem.sliceTo(job.config.sequence_path[0..], 0);
            if (seq_path.len == 0) {
                job.status = .failed;
                const msg = "No sequence path specified";
                @memset(job.status_message[0..], 0);
                @memcpy(job.status_message[0..msg.len], msg);
                advanceToNextJob(rq_state);
                return;
            }

            // Configure the existing render output fields on EditorState
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

            // Copy output dir as the output path
            const out_dir = std.mem.sliceTo(job.config.output_dir[0..], 0);
            @memset(state.render_output_path_buffer[0..], 0);
            const copy_len = @min(out_dir.len, state.render_output_path_buffer.len - 1);
            @memcpy(state.render_output_path_buffer[0..copy_len], out_dir[0..copy_len]);

            // Enable sequence export mode
            state.render_output_sequence_enabled = true;
            if (job.config.use_path_trace) {
                state.viewport_pipeline_mode = .path_trace;
            }

            // Load the sequence to determine total frames
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

            // Kick off the first frame via the existing render output system
            state.render_output_job_stage = .resize_and_render;
            state.render_output_job_is_sequence = true;
            state.render_output_job_total_frames = total;
            state.render_output_job_frame_index = 0;
        },
        .rendering => {
            // Track progress from the existing render output state machine
            job.current_frame = state.render_output_job_frame_index;

            // Check if the existing state machine finished
            if (state.render_output_job_stage == .idle and state.render_output_status == .success) {
                job.current_frame = job.total_frames;
                state.render_output_use_cinematic_sequence = false;

                // Optionally encode video via FFmpeg
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
