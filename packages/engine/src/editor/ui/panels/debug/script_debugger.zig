const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

const DebugSession = engine.script.DebugSession;
const Breakpoint = engine.script.Breakpoint;
const DapAdapter = engine.script.DapAdapter;

/// DAP server state — runs on a background thread serving one connection at a time.
const DapServerState = enum {
    stopped,
    listening,
    connected,
    err,
};

/// Persistent state for the script debugger panel.
pub const ScriptDebuggerState = struct {
    bp_line_buf: [16]u8 = [_]u8{0} ** 16,
    bp_handle_buf: [32]u8 = [_]u8{0} ** 32,
    selected_instance: ?u64 = null,
    dap_server_state: DapServerState = .stopped,
    dap_server_thread: ?std.Thread = null,
    dap_port: u16 = 4711,
    dap_port_buf: [8]u8 = [_]u8{ '4', '7', '1', '1', 0, 0, 0, 0 },
    dap_status_msg: [128]u8 = [_]u8{0} ** 128,
    dap_status_len: usize = 0,
};

/// Draw the Script Debugger panel.
pub fn drawScriptDebuggerWindow(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    dbg_state: *ScriptDebuggerState,
) !void {
    var open = state.script_debugger_open;
    const open_window = gui.beginWindowOpen("Script Debugger###script_debugger_panel", &open);
    floating_window_blocker.registerCurrentWindow("script_debugger_panel");
    if (!open_window) {
        gui.endWindow();
        state.script_debugger_open = open;
        return;
    }
    defer {
        gui.endWindow();
        state.script_debugger_open = open;
    }

    const debug_session = layer_context.script_debug_session orelse {
        gui.text("Debug session not available.");
        return;
    };

    // ── Toolbar ──────────────────────────────────────────────────────────
    drawToolbar(debug_session);
    gui.separator();

    // ── Tabs ─────────────────────────────────────────────────────────────
    if (gui.beginTabBar("debugger_tabs")) {
        if (gui.beginTabItem("Breakpoints")) {
            drawBreakpointsTab(debug_session, dbg_state);
            gui.endTabItem();
        }
        if (gui.beginTabItem("Call Stack")) {
            drawCallStackTab(debug_session, layer_context);
            gui.endTabItem();
        }
        if (gui.beginTabItem("Variables")) {
            try drawVariablesTab(debug_session, layer_context);
            gui.endTabItem();
        }
        if (gui.beginTabItem("Sessions")) {
            drawSessionsTab(debug_session);
            gui.endTabItem();
        }
        if (gui.beginTabItem("DAP Server")) {
            drawDapTab(debug_session, dbg_state);
            gui.endTabItem();
        }
        gui.endTabBar();
    }
}

// ── Toolbar ──────────────────────────────────────────────────────────────────

fn drawToolbar(debug_session: *DebugSession) void {
    // Enable/disable toggle
    if (debug_session.enabled) {
        if (gui.button("Disable")) {
            debug_session.enabled = false;
            debug_session.resumeAll();
        }
    } else {
        if (gui.button("Enable")) {
            debug_session.enabled = true;
        }
    }
    gui.sameLine();

    // Pause / Resume
    if (debug_session.isPaused()) {
        if (gui.button("Resume All")) {
            debug_session.resumeAll();
        }
        gui.sameLine();
        if (gui.button("Step")) {
            // Step-into: pause on next update for all sessions
            var it_step = debug_session.sessions.iterator();
            while (it_step.next()) |entry| {
                if (entry.value_ptr.state == .paused) {
                    entry.value_ptr.state = .stepping;
                    entry.value_ptr.step_mode = .step_into;
                }
            }
        }
    } else {
        if (gui.button("Pause All")) {
            debug_session.pauseAll();
        }
    }

    gui.sameLine();
    var status_buf: [64]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buf, "Sessions: {d}  BPs: {d}", .{
        debug_session.activeSessionCount(),
        debug_session.getBreakpoints().len,
    }) catch "?";
    gui.text(status_text);
}

// ── Breakpoints tab ──────────────────────────────────────────────────────────

fn drawBreakpointsTab(debug_session: *DebugSession, dbg_state: *ScriptDebuggerState) void {
    // Add breakpoint form
    gui.text("Script Handle:");
    gui.sameLine();
    _ = gui.inputText("##bp_handle", &dbg_state.bp_handle_buf);
    gui.sameLine();
    gui.text("Line:");
    gui.sameLine();
    _ = gui.inputText("##bp_line", &dbg_state.bp_line_buf);
    gui.sameLine();

    if (gui.button("Add BP")) {
        const handle_str = std.mem.sliceTo(&dbg_state.bp_handle_buf, 0);
        const line_str = std.mem.sliceTo(&dbg_state.bp_line_buf, 0);
        const handle = std.fmt.parseInt(u64, handle_str, 10) catch 0;
        const line = std.fmt.parseInt(u32, line_str, 10) catch 0;
        if (handle != 0 and line != 0) {
            _ = debug_session.addBreakpoint(handle, line) catch {};
        }
    }
    gui.sameLine();
    if (gui.button("Clear All")) {
        debug_session.clearAllBreakpoints();
    }

    gui.separator();

    // Breakpoint list
    if (gui.beginTable("bp_table", 5)) {
        gui.tableSetupColumn("ID", true, 0.0);
        gui.tableSetupColumn("Handle", true, 0.0);
        gui.tableSetupColumn("Line", true, 0.0);
        gui.tableSetupColumn("Hits", true, 0.0);
        gui.tableSetupColumn("Actions", true, 0.0);
        gui.tableHeadersRow();

        var remove_id: ?u32 = null;
        for (debug_session.getBreakpoints()) |bp| {
            gui.tableNextRow();

            gui.tableNextColumn();
            var id_buf: [16]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "#{d}", .{bp.id}) catch "?";
            if (bp.enabled) {
                gui.text(id_str);
            } else {
                gui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, id_str);
            }

            gui.tableNextColumn();
            var handle_buf: [32]u8 = undefined;
            const handle_str = std.fmt.bufPrint(&handle_buf, "{d}", .{bp.script_handle}) catch "?";
            gui.text(handle_str);

            gui.tableNextColumn();
            var line_buf: [16]u8 = undefined;
            const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{bp.line}) catch "?";
            gui.text(line_str);

            gui.tableNextColumn();
            var hit_buf: [16]u8 = undefined;
            const hit_str = std.fmt.bufPrint(&hit_buf, "{d}", .{bp.hit_count}) catch "?";
            gui.text(hit_str);

            gui.tableNextColumn();
            var toggle_label_buf: [32]u8 = undefined;
            const toggle_label = std.fmt.bufPrint(&toggle_label_buf, "{s}##toggle_{d}", .{
                if (bp.enabled) "Disable" else "Enable",
                bp.id,
            }) catch "?";
            if (gui.button(toggle_label)) {
                debug_session.toggleBreakpoint(bp.id);
            }
            gui.sameLine();
            var del_label_buf: [32]u8 = undefined;
            const del_label = std.fmt.bufPrint(&del_label_buf, "Del##del_{d}", .{bp.id}) catch "?";
            if (gui.button(del_label)) {
                remove_id = bp.id;
            }
        }

        gui.endTable();

        // Deferred removal
        if (remove_id) |rid| {
            debug_session.removeBreakpoint(rid);
        }
    }
}

// ── Call Stack tab ───────────────────────────────────────────────────────────

fn drawCallStackTab(debug_session: *DebugSession, layer_context: *engine.core.LayerContext) void {
    _ = layer_context;

    if (!debug_session.isPaused()) {
        gui.text("Not paused — call stack unavailable.");
        return;
    }

    gui.text("Call stack:");
    gui.separator();

    // Show call stack for each paused session
    var it_cs = debug_session.sessions.iterator();
    while (it_cs.next()) |entry| {
        const session = entry.value_ptr;
        if (session.state != .paused) continue;

        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "Instance {d}", .{session.instance_id}) catch "?";

        if (gui.collapsingHeader(label, false)) {
            if (session.call_stack_buf.len > 0) {
                gui.textWrapped(session.call_stack_buf);
            } else {
                gui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "(no call stack captured)");
            }
        }
    }
}

// ── Variables tab ────────────────────────────────────────────────────────────

fn drawVariablesTab(debug_session: *DebugSession, layer_context: *engine.core.LayerContext) !void {
    if (!debug_session.isPaused()) {
        gui.text("Not paused — variables unavailable.");
        return;
    }

    const runtime = layer_context.script_runtime orelse {
        gui.text("Script runtime not available.");
        return;
    };

    // Show variables for each paused session
    var it_vars = debug_session.sessions.iterator();
    while (it_vars.next()) |entry| {
        const session = entry.value_ptr;
        if (session.state != .paused) continue;

        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "Instance {d}###vars_{d}", .{ session.instance_id, session.instance_id }) catch "?";

        if (gui.collapsingHeader(label, false)) {
            const instance = runtime.instances.get(session.instance_id) orelse {
                gui.text("(instance not found)");
                continue;
            };

            // Use a temp allocator for variable capture
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const variables = debug_session.captureVariables(arena.allocator(), instance) catch {
                gui.text("(failed to capture variables)");
                continue;
            };

            if (variables.len == 0) {
                gui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "(no reflected parameters)");
                continue;
            }

            if (gui.beginTable("var_table", 3)) {
                gui.tableSetupColumn("Name", true, 0.0);
                gui.tableSetupColumn("Type", true, 0.0);
                gui.tableSetupColumn("Value", true, 0.0);
                gui.tableHeadersRow();

                for (variables) |v| {
                    gui.tableNextRow();
                    gui.tableNextColumn();
                    gui.text(v.name);

                    gui.tableNextColumn();
                    gui.text(@tagName(v.kind));

                    gui.tableNextColumn();
                    var val_buf: [64]u8 = undefined;
                    const val_str = switch (v.kind) {
                        .float => std.fmt.bufPrint(&val_buf, "{d:.4}", .{v.value_float}) catch "?",
                        .boolean => if (v.value_bool) "true" else "false",
                        .integer => std.fmt.bufPrint(&val_buf, "{d}", .{v.value_int}) catch "?",
                    };
                    gui.text(val_str);
                }

                gui.endTable();
            }
        }
    }
}

// ── Sessions tab ─────────────────────────────────────────────────────────────

fn drawSessionsTab(debug_session: *DebugSession) void {
    if (debug_session.activeSessionCount() == 0) {
        gui.text("No debug sessions active.");
        return;
    }

    if (gui.beginTable("session_table", 4)) {
        gui.tableSetupColumn("Instance", true, 0.0);
        gui.tableSetupColumn("Handle", true, 0.0);
        gui.tableSetupColumn("State", true, 0.0);
        gui.tableSetupColumn("Actions", true, 0.0);
        gui.tableHeadersRow();

        var it_tbl = debug_session.sessions.iterator();
        while (it_tbl.next()) |entry| {
            const session = entry.value_ptr;
            gui.tableNextRow();

            gui.tableNextColumn();
            var id_buf: [32]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{session.instance_id}) catch "?";
            gui.text(id_str);

            gui.tableNextColumn();
            var handle_buf: [32]u8 = undefined;
            const handle_str = std.fmt.bufPrint(&handle_buf, "{d}", .{session.script_handle}) catch "?";
            gui.text(handle_str);

            gui.tableNextColumn();
            switch (session.state) {
                .running => gui.textColored(.{ 0.3, 0.9, 0.3, 1.0 }, "running"),
                .paused => gui.textColored(.{ 1.0, 0.8, 0.2, 1.0 }, "paused"),
                .stepping => gui.textColored(.{ 0.5, 0.8, 1.0, 1.0 }, "stepping"),
            }

            gui.tableNextColumn();
            switch (session.state) {
                .paused => {
                    var resume_label: [32]u8 = undefined;
                    const rl = std.fmt.bufPrint(&resume_label, "Resume##r_{d}", .{session.instance_id}) catch "?";
                    if (gui.button(rl)) {
                        debug_session.resumeInstance(session.instance_id);
                    }
                    gui.sameLine();
                    var step_label: [32]u8 = undefined;
                    const sl = std.fmt.bufPrint(&step_label, "Step##s_{d}", .{session.instance_id}) catch "?";
                    if (gui.button(sl)) {
                        debug_session.stepInstance(session.instance_id, .step_into);
                    }
                },
                .running => {
                    var pause_label: [32]u8 = undefined;
                    const pl = std.fmt.bufPrint(&pause_label, "Pause##p_{d}", .{session.instance_id}) catch "?";
                    if (gui.button(pl)) {
                        if (debug_session.sessions.getPtr(session.instance_id)) |s| {
                            s.state = .paused;
                        }
                    }
                },
                .stepping => gui.text("..."),
            }
        }

        gui.endTable();
    }
}

// ── DAP Server tab ───────────────────────────────────────────────────────────

fn drawDapTab(debug_session: *DebugSession, dbg_state: *ScriptDebuggerState) void {
    gui.textWrapped("Connect VS Code or any DAP client to debug scripts remotely.");
    gui.spacing();

    // Status indicator
    const status_color: [4]f32 = switch (dbg_state.dap_server_state) {
        .stopped => .{ 0.5, 0.5, 0.5, 1.0 },
        .listening => .{ 1.0, 0.85, 0.3, 1.0 },
        .connected => .{ 0.3, 1.0, 0.4, 1.0 },
        .err => .{ 1.0, 0.3, 0.3, 1.0 },
    };
    const status_label = switch (dbg_state.dap_server_state) {
        .stopped => "Stopped",
        .listening => "Listening...",
        .connected => "Client connected",
        .err => "Error",
    };
    gui.textColored(status_color, status_label);

    if (dbg_state.dap_status_len > 0) {
        gui.sameLine();
        gui.textColored(.{ 0.7, 0.7, 0.7, 1.0 }, dbg_state.dap_status_msg[0..dbg_state.dap_status_len]);
    }

    gui.spacing();
    gui.separator();
    gui.spacing();

    // Port input
    gui.text("Port:");
    gui.sameLine();
    gui.setNextItemWidth(80.0);
    _ = gui.inputText("##dap_port", &dbg_state.dap_port_buf);

    gui.sameLine();

    switch (dbg_state.dap_server_state) {
        .stopped, .err => {
            if (gui.button("Start DAP Server")) {
                const port_str = std.mem.sliceTo(&dbg_state.dap_port_buf, 0);
                dbg_state.dap_port = std.fmt.parseInt(u16, port_str, 10) catch 4711;
                startDapServer(debug_session, dbg_state);
            }
        },
        .listening, .connected => {
            if (gui.button("Stop")) {
                // Signal stop by setting state; the thread will see it on next iteration
                dbg_state.dap_server_state = .stopped;
            }
        },
    }

    gui.spacing();
    gui.separator();
    gui.spacing();

    // Connection instructions
    gui.textWrapped("In VS Code, add to launch.json:");
    gui.pushStyleColor(.text, .{ 0.75, 0.85, 0.95, 1.0 });
    var port_text_buf: [256]u8 = undefined;
    const port_text = std.fmt.bufPrint(&port_text_buf,
        \\{{
        \\  "type": "guava-script",
        \\  "request": "attach",
        \\  "name": "Attach to Guava",
        \\  "port": {d}
        \\}}
    , .{dbg_state.dap_port}) catch "{}";
    gui.textWrapped(port_text);
    gui.popStyleColor(1);
}

fn startDapServer(debug_session: *DebugSession, dbg_state: *ScriptDebuggerState) void {
    if (dbg_state.dap_server_state == .listening or dbg_state.dap_server_state == .connected) return;

    dbg_state.dap_server_state = .listening;
    setDapStatus(dbg_state, "Starting...");

    const Context = struct {
        debug_session: *DebugSession,
        dbg_state: *ScriptDebuggerState,
    };
    const ctx = Context{
        .debug_session = debug_session,
        .dbg_state = dbg_state,
    };

    dbg_state.dap_server_thread = std.Thread.spawn(.{}, struct {
        fn worker(c: Context) void {
            dapServerLoop(c.debug_session, c.dbg_state);
        }
    }.worker, .{ctx}) catch {
        dbg_state.dap_server_state = .err;
        setDapStatus(dbg_state, "Failed to start thread");
        return;
    };
}

fn dapServerLoop(debug_session: *DebugSession, dbg_state: *ScriptDebuggerState) void {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, dbg_state.dap_port);
    var server = address.listen(.{
        .reuse_address = true,
    }) catch {
        dbg_state.dap_server_state = .err;
        setDapStatus(dbg_state, "Failed to bind port");
        return;
    };
    defer server.deinit();

    var port_buf: [32]u8 = undefined;
    setDapStatus(dbg_state, std.fmt.bufPrint(&port_buf, "Listening on :{d}", .{dbg_state.dap_port}) catch "Listening");

    while (dbg_state.dap_server_state == .listening or dbg_state.dap_server_state == .connected) {
        // Accept one client at a time
        const conn = server.accept() catch {
            if (dbg_state.dap_server_state == .stopped) return;
            continue;
        };
        defer conn.stream.close();

        dbg_state.dap_server_state = .connected;
        setDapStatus(dbg_state, "Client connected");

        // Run DAP protocol over this connection
        // Wrap net.Stream into GenericReader/GenericWriter to get AnyReader/AnyWriter
        var stream_ctx = conn.stream;
        const StreamReader = std.io.GenericReader(*std.net.Stream, std.posix.ReadError, struct {
            fn read(ctx: *std.net.Stream, buf: []u8) std.posix.ReadError!usize {
                return std.posix.read(ctx.handle, buf);
            }
        }.read);
        const StreamWriter = std.io.GenericWriter(*std.net.Stream, std.posix.WriteError, struct {
            fn write(ctx: *std.net.Stream, data: []const u8) std.posix.WriteError!usize {
                return std.posix.write(ctx.handle, data);
            }
        }.write);
        var stream_reader: StreamReader = .{ .context = &stream_ctx };
        var stream_writer: StreamWriter = .{ .context = &stream_ctx };
        var adapter = DapAdapter.init(
            std.heap.page_allocator,
            debug_session,
            stream_reader.any(),
            stream_writer.any(),
        );
        defer adapter.deinit();

        adapter.run() catch {};

        // Client disconnected — go back to listening
        if (dbg_state.dap_server_state != .stopped) {
            dbg_state.dap_server_state = .listening;
            setDapStatus(dbg_state, std.fmt.bufPrint(&port_buf, "Listening on :{d}", .{dbg_state.dap_port}) catch "Listening");
        }
    }
}

fn setDapStatus(dbg_state: *ScriptDebuggerState, msg: []const u8) void {
    const len = @min(msg.len, dbg_state.dap_status_msg.len);
    @memcpy(dbg_state.dap_status_msg[0..len], msg[0..len]);
    dbg_state.dap_status_len = len;
}
