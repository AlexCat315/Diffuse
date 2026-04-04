const std = @import("std");
const debug_session_mod = @import("debug_session.zig");
const types = @import("types.zig");

const DebugSession = debug_session_mod.DebugSession;
const Breakpoint = debug_session_mod.Breakpoint;
const StepMode = debug_session_mod.StepMode;

const log = std.log.scoped(.dap_adapter);

/// DAP (Debug Adapter Protocol) adapter that bridges the engine's
/// DebugSession to the DAP JSON wire protocol.
///
/// Protocol reference: https://microsoft.github.io/debug-adapter-protocol/
///
/// Usage:
///   1. Create a DapAdapter bound to an existing DebugSession
///   2. Call `run()` to enter the read-dispatch loop (blocking)
///   3. Or call `processMessage()` for single-message handling
pub const DapAdapter = struct {
    allocator: std.mem.Allocator,
    debug_session: *DebugSession,
    seq: i64 = 1,
    initialized: bool = false,
    /// Output buffer for sending DAP messages.
    output_buf: std.ArrayList(u8),
    /// Reader/writer for the DAP transport (typically stdin/stdout).
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,

    pub fn init(
        allocator: std.mem.Allocator,
        debug_session: *DebugSession,
        reader: std.io.AnyReader,
        writer: std.io.AnyWriter,
    ) DapAdapter {
        return .{
            .allocator = allocator,
            .debug_session = debug_session,
            .output_buf = .{},
            .reader = reader,
            .writer = writer,
        };
    }

    pub fn deinit(self: *DapAdapter) void {
        self.output_buf.deinit(self.allocator);
    }

    /// Blocking read-dispatch loop. Reads DAP messages from stdin and
    /// dispatches them until the connection closes or a disconnect is received.
    pub fn run(self: *DapAdapter) !void {
        while (true) {
            const message = self.readMessage() catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            defer self.allocator.free(message);

            self.processMessage(message) catch |err| {
                log.warn("DAP message processing error: {s}", .{@errorName(err)});
            };
        }
    }

    /// Read a single DAP message (Content-Length header + JSON body).
    fn readMessage(self: *DapAdapter) ![]u8 {
        var content_length: usize = 0;

        // Read headers
        while (true) {
            var line_buf: [256]u8 = undefined;
            const line = try self.reader.readUntilDelimiter(&line_buf, '\n');
            const trimmed = std.mem.trimRight(u8, line, "\r\n");

            if (trimmed.len == 0) break; // Empty line = end of headers

            if (std.mem.startsWith(u8, trimmed, "Content-Length: ")) {
                content_length = std.fmt.parseInt(usize, trimmed["Content-Length: ".len..], 10) catch 0;
            }
        }

        if (content_length == 0) return error.InvalidMessage;

        const body = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body);

        var total_read: usize = 0;
        while (total_read < content_length) {
            const n = try self.reader.read(body[total_read..]);
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }

        return body;
    }

    /// Process a single DAP JSON message.
    pub fn processMessage(self: *DapAdapter, message: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{}) catch {
            log.warn("DAP: invalid JSON", .{});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const msg_type = getStr(root, "type") orelse return;
        const command = getStr(root, "command") orelse "";
        const request_seq = getInt(root, "seq") orelse 0;

        if (std.mem.eql(u8, msg_type, "request")) {
            try self.handleRequest(command, request_seq, root);
        }
    }

    fn handleRequest(self: *DapAdapter, command: []const u8, request_seq: i64, root: std.json.Value) !void {
        if (std.mem.eql(u8, command, "initialize")) {
            try self.handleInitialize(request_seq);
        } else if (std.mem.eql(u8, command, "launch") or std.mem.eql(u8, command, "attach")) {
            try self.handleLaunch(request_seq);
        } else if (std.mem.eql(u8, command, "disconnect")) {
            try self.handleDisconnect(request_seq);
        } else if (std.mem.eql(u8, command, "setBreakpoints")) {
            try self.handleSetBreakpoints(request_seq, root);
        } else if (std.mem.eql(u8, command, "threads")) {
            try self.handleThreads(request_seq);
        } else if (std.mem.eql(u8, command, "stackTrace")) {
            try self.handleStackTrace(request_seq, root);
        } else if (std.mem.eql(u8, command, "scopes")) {
            try self.handleScopes(request_seq, root);
        } else if (std.mem.eql(u8, command, "variables")) {
            try self.handleVariables(request_seq, root);
        } else if (std.mem.eql(u8, command, "continue")) {
            try self.handleContinue(request_seq, root);
        } else if (std.mem.eql(u8, command, "next")) {
            try self.handleNext(request_seq, root);
        } else if (std.mem.eql(u8, command, "stepIn")) {
            try self.handleStepIn(request_seq, root);
        } else if (std.mem.eql(u8, command, "pause")) {
            try self.handlePause(request_seq, root);
        } else if (std.mem.eql(u8, command, "configurationDone")) {
            try self.sendResponse(request_seq, command, true, null);
        } else {
            try self.sendResponse(request_seq, command, false, "Unsupported command");
        }
    }

    // ── Handler implementations ──────────────────────────────────────────

    fn handleInitialize(self: *DapAdapter, request_seq: i64) !void {
        self.initialized = true;
        self.debug_session.enabled = true;

        // Send capabilities
        var body_buf: [512]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf,
            \\{{"supportsConfigurationDoneRequest":true,"supportsFunctionBreakpoints":false,"supportsConditionalBreakpoints":false,"supportsEvaluateForHovers":false,"supportsStepBack":false,"supportsSetVariable":false}}
        , .{});

        try self.sendResponseWithBody(request_seq, "initialize", body);
        try self.sendEvent("initialized", "{}");
    }

    fn handleLaunch(self: *DapAdapter, request_seq: i64) !void {
        try self.sendResponse(request_seq, "attach", true, null);
    }

    fn handleDisconnect(self: *DapAdapter, request_seq: i64) !void {
        self.debug_session.enabled = false;
        self.debug_session.resumeAll();
        try self.sendResponse(request_seq, "disconnect", true, null);
    }

    fn handleSetBreakpoints(self: *DapAdapter, request_seq: i64, root: std.json.Value) !void {
        const args = root.object.get("arguments") orelse return;
        const source = args.object.get("source") orelse return;
        const source_path = getStr(source, "path") orelse "";

        // Clear existing breakpoints for this source
        // Use path hash as script_handle for simplicity
        const script_handle = std.hash.Wyhash.hash(0, source_path);

        // Remove old breakpoints for this handle
        var i: usize = 0;
        while (i < self.debug_session.breakpoints.items.len) {
            if (self.debug_session.breakpoints.items[i].script_handle == script_handle) {
                _ = self.debug_session.breakpoints.swapRemove(i);
            } else {
                i += 1;
            }
        }

        // Add new breakpoints
        var bp_array_buf: [2048]u8 = undefined;
        var bp_stream = std.io.fixedBufferStream(&bp_array_buf);
        const bp_writer = bp_stream.writer();
        try bp_writer.writeAll("[");

        var first = true;
        if (args.object.get("breakpoints")) |bps| {
            if (bps == .array) {
                for (bps.array.items) |bp_val| {
                    const line = getInt(bp_val, "line") orelse continue;
                    const bp_id = self.debug_session.addBreakpoint(script_handle, @intCast(line)) catch continue;

                    if (!first) try bp_writer.writeAll(",");
                    first = false;
                    try std.fmt.format(bp_writer, "{{\"{s}\":{d},\"{s}\":{d},\"{s}\":true}}", .{
                        "id",       bp_id,
                        "line",     line,
                        "verified",
                    });
                }
            }
        }
        try bp_writer.writeAll("]");

        var resp_buf: [2048]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf,
            \\{{"breakpoints":{s}}}
        , .{bp_stream.getWritten()});

        try self.sendResponseWithBody(request_seq, "setBreakpoints", resp);
    }

    fn handleThreads(self: *DapAdapter, request_seq: i64) !void {
        // Map each script instance session to a thread
        var buf: [2048]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();

        try w.writeAll("{\"threads\":[");
        var first = true;
        var it = self.debug_session.sessions.iterator();
        while (it.next()) |entry| {
            if (!first) try w.writeAll(",");
            first = false;
            try std.fmt.format(w, "{{\"id\":{d},\"name\":\"Script {d}\"}}", .{
                entry.key_ptr.*,
                entry.key_ptr.*,
            });
        }
        // Always provide at least one thread
        if (first) {
            try w.writeAll("{\"id\":1,\"name\":\"Main\"}");
        }
        try w.writeAll("]}");

        try self.sendResponseWithBody(request_seq, "threads", stream.getWritten());
    }

    fn handleStackTrace(self: *DapAdapter, request_seq: i64, root: std.json.Value) !void {
        const args = root.object.get("arguments") orelse return;
        const thread_id = getInt(args, "threadId") orelse 1;

        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();

        try w.writeAll("{\"stackFrames\":[");

        // Try to get call stack from the session
        if (self.debug_session.sessions.getPtr(@intCast(thread_id))) |session| {
            if (session.call_stack_buf.len > 0) {
                // Parse call stack text into stack frames
                try std.fmt.format(w, "{{\"id\":0,\"name\":\"{s}\",\"line\":0,\"column\":0,\"source\":{{\"name\":\"script\"}}}}", .{
                    std.mem.sliceTo(session.call_stack_buf, '\n'),
                });
            } else {
                try w.writeAll("{\"id\":0,\"name\":\"(unknown)\",\"line\":0,\"column\":0}");
            }
        } else {
            try w.writeAll("{\"id\":0,\"name\":\"(no frame)\",\"line\":0,\"column\":0}");
        }

        try w.writeAll("],\"totalFrames\":1}");
        try self.sendResponseWithBody(request_seq, "stackTrace", stream.getWritten());
    }

    fn handleScopes(self: *DapAdapter, request_seq: i64, root: std.json.Value) !void {
        _ = root;
        const body =
            \\{"scopes":[{"name":"Locals","variablesReference":1,"expensive":false}]}
        ;
        try self.sendResponseWithBody(request_seq, "scopes", body);
    }

    fn handleVariables(self: *DapAdapter, request_seq: i64, root: std.json.Value) !void {
        _ = root;
        // Collect variables from all paused sessions
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();
        try w.writeAll("{\"variables\":[");

        var first = true;
        var it = self.debug_session.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state != .paused) continue;

            // Get instance from the session info
            const instance_id = entry.key_ptr.*;
            _ = instance_id;
            // Variables are captured per-instance; for now show basic info
            if (!first) try w.writeAll(",");
            first = false;
            try std.fmt.format(w, "{{\"name\":\"instance\",\"value\":\"{d}\",\"variablesReference\":0}}", .{
                entry.key_ptr.*,
            });
        }

        try w.writeAll("]}");
        try self.sendResponseWithBody(request_seq, "variables", stream.getWritten());
    }

    fn handleContinue(self: *DapAdapter, request_seq: i64, root: std.json.Value) !void {
        const args = root.object.get("arguments") orelse {
            self.debug_session.resumeAll();
            try self.sendResponseWithBody(request_seq, "continue", "{\"allThreadsContinued\":true}");
            return;
        };
        const thread_id = getInt(args, "threadId");
        if (thread_id) |tid| {
            self.debug_session.resumeInstance(@intCast(tid));
            try self.sendResponseWithBody(request_seq, "continue", "{\"allThreadsContinued\":false}");
        } else {
            self.debug_session.resumeAll();
            try self.sendResponseWithBody(request_seq, "continue", "{\"allThreadsContinued\":true}");
        }
    }

    fn handleNext(self: *DapAdapter, request_seq: i64, root: std.json.Value) !void {
        const args = root.object.get("arguments") orelse return;
        const tid = getInt(args, "threadId") orelse return;
        self.debug_session.stepInstance(@intCast(tid), .step_over);
        try self.sendResponse(request_seq, "next", true, null);
    }

    fn handleStepIn(self: *DapAdapter, request_seq: i64, root: std.json.Value) !void {
        const args = root.object.get("arguments") orelse return;
        const tid = getInt(args, "threadId") orelse return;
        self.debug_session.stepInstance(@intCast(tid), .step_into);
        try self.sendResponse(request_seq, "stepIn", true, null);
    }

    fn handlePause(self: *DapAdapter, request_seq: i64, root: std.json.Value) !void {
        _ = root;
        self.debug_session.pauseAll();
        try self.sendResponse(request_seq, "pause", true, null);
        try self.sendEvent("stopped", "{\"reason\":\"pause\",\"threadId\":1,\"allThreadsStopped\":true}");
    }

    // ── DAP message sending ──────────────────────────────────────────────

    fn sendResponse(self: *DapAdapter, request_seq: i64, command: []const u8, success: bool, message: ?[]const u8) !void {
        var buf: [512]u8 = undefined;
        const body = if (message) |msg|
            try std.fmt.bufPrint(&buf,
                \\{{"seq":{d},"type":"response","request_seq":{d},"success":{s},"command":"{s}","message":"{s}"}}
            , .{ self.seq, request_seq, if (success) "true" else "false", command, msg })
        else
            try std.fmt.bufPrint(&buf,
                \\{{"seq":{d},"type":"response","request_seq":{d},"success":{s},"command":"{s}"}}
            , .{ self.seq, request_seq, if (success) "true" else "false", command });

        self.seq += 1;
        try self.writeMessage(body);
    }

    fn sendResponseWithBody(self: *DapAdapter, request_seq: i64, command: []const u8, body_json: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            \\{{"seq":{d},"type":"response","request_seq":{d},"success":true,"command":"{s}","body":{s}}}
        , .{ self.seq, request_seq, command, body_json });
        self.seq += 1;
        try self.writeMessage(msg);
    }

    fn sendEvent(self: *DapAdapter, event: []const u8, body_json: []const u8) !void {
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            \\{{"seq":{d},"type":"event","event":"{s}","body":{s}}}
        , .{ self.seq, event, body_json });
        self.seq += 1;
        try self.writeMessage(msg);
    }

    /// Send a stopped event (breakpoint hit, step completed, etc.)
    pub fn notifyStopped(self: *DapAdapter, reason: []const u8, thread_id: u64) !void {
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf,
            \\{{"reason":"{s}","threadId":{d},"allThreadsStopped":false}}
        , .{ reason, thread_id });
        try self.sendEvent("stopped", body);
    }

    fn writeMessage(self: *DapAdapter, json_body: []const u8) !void {
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{json_body.len});
        try self.writer.writeAll(header);
        try self.writer.writeAll(json_body);
    }

    // ── JSON helpers ─────────────────────────────────────────────────────

    fn getStr(val: std.json.Value, key: []const u8) ?[]const u8 {
        if (val != .object) return null;
        const v = val.object.get(key) orelse return null;
        if (v != .string) return null;
        return v.string;
    }

    fn getInt(val: std.json.Value, key: []const u8) ?i64 {
        if (val != .object) return null;
        const v = val.object.get(key) orelse return null;
        if (v != .integer) return null;
        return v.integer;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "DapAdapter: initialize handshake" {
    const allocator = std.testing.allocator;
    var ds = DebugSession.init(allocator);
    defer ds.deinit();

    const init_msg =
        \\{"seq":1,"type":"request","command":"initialize","arguments":{"clientID":"vscode"}}
    ;

    var out_buf: [8192]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buf);

    var in_buf: [512]u8 = undefined;
    var in_stream = std.io.fixedBufferStream(&in_buf);
    const header = std.fmt.bufPrint(in_buf[0..64], "Content-Length: {d}\r\n\r\n", .{init_msg.len}) catch unreachable;
    @memcpy(in_buf[header.len .. header.len + init_msg.len], init_msg);

    var adapter = DapAdapter.init(
        allocator,
        &ds,
        in_stream.reader().any(),
        out_stream.writer().any(),
    );
    defer adapter.deinit();

    try adapter.processMessage(init_msg);
    try std.testing.expect(adapter.initialized);
    try std.testing.expect(ds.enabled);
}
