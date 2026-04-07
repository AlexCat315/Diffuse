///! Editor RPC server — WebSocket JSON-RPC 2.0 server for Electron editor.
///!
///! Runs a TCP listener on localhost, accepts WebSocket connections,
///! and dispatches JSON-RPC requests to engine systems. Sends push
///! notifications for state changes (scene, selection, console, etc.).
///!
///! Designed to integrate as a Layer in the Application layer stack,
///! processing pending requests each frame on the main thread.
const std = @import("std");
const ws = @import("websocket.zig");
const methods = @import("dispatch.zig");
const subscriptions = @import("subscriptions.zig");
const core = @import("../core/layer.zig");

const log = std.log.scoped(.editor_rpc);

const max_clients = 8;
const max_console_log_entries = 256;

/// A buffered console log entry for broadcasting to the editor.
pub const ConsoleLogEntry = struct {
    level: [8]u8 = undefined,
    level_len: u8 = 0,
    source: [64]u8 = undefined,
    source_len: u8 = 0,
    message: [512]u8 = undefined,
    message_len: u16 = 0,
};

/// Global server pointer for console log API.
var global_server: ?*Server = null;

/// Push a console log entry to the editor. Thread-safe, can be called from anywhere.
pub fn consoleLog(level: []const u8, message: []const u8, source: ?[]const u8) void {
    const srv = global_server orelse return;
    srv.pushConsoleLog(level, message, source);
}

/// Notify the editor that a new IOSurface frame is ready for readback.
/// Called from the renderer right after waitForGpu() completes, while
/// the IOSurface pixels are stable (before next drawFrame starts).
/// Broadcasts + flushes immediately so the editor can read within the
/// safe window (before the next frame's GPU commands touch the surface).
pub fn notifyFrameReady() void {
    const srv = global_server orelse return;
    if (srv.active_client_count.load(.acquire) == 0) return;
    const msg = "{\"jsonrpc\":\"2.0\",\"method\":\"on:viewport.frameReady\",\"params\":{}}";
    const owned = srv.allocator.dupe(u8, msg) catch return;
    srv.broadcast(owned);
    srv.flushOutgoing();
}

/// Callback trampoline for the logging system (matches the function pointer signature).
pub fn consoleLogTrampoline(level: []const u8, message: []const u8, source: []const u8) void {
    consoleLog(level, message, source);
}

/// A connected WebSocket client with its own send queue.
const Client = struct {
    stream: std.net.Stream,
    alive: bool = true,
    id: u32 = 0,
};

/// Thread-safe message queue for incoming RPC requests.
const IncomingMessage = struct {
    client_id: u32,
    payload: []u8,

    fn deinit(self: *IncomingMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

/// Thread-safe message queue for outgoing responses/notifications.
const OutgoingMessage = struct {
    client_id: u32, // 0 = broadcast to all
    payload: []u8,

    fn deinit(self: *OutgoingMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,
    listener_thread: ?std.Thread = null,
    client_threads: [max_clients]?std.Thread = .{null} ** max_clients,

    // Thread-safe queues
    incoming_mutex: std.Thread.Mutex = .{},
    incoming: std.ArrayList(IncomingMessage) = .empty,
    outgoing_mutex: std.Thread.Mutex = .{},
    outgoing: std.ArrayList(OutgoingMessage) = .empty,

    // Connected clients (accessed from listener + client threads)
    clients_mutex: std.Thread.Mutex = .{},
    clients: [max_clients]?Client = .{null} ** max_clients,
    next_client_id: u32 = 1,

    // Shutdown signal
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_client_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Subscription state tracking
    sub_state: subscriptions.SubscriptionState = .{},

    // Console log ring buffer
    console_log_mutex: std.Thread.Mutex = .{},
    console_log_buf: [max_console_log_entries]ConsoleLogEntry = undefined,
    console_log_head: u32 = 0,
    console_log_count: u32 = 0,

    // Shared editor settings (viewport, physics viz, camera bookmarks, material preview)
    settings: @import("settings.zig").EditorSettings = .{},

    // Mesh editing vtable — set from main.zig (root module) to avoid cross-module imports.
    mesh_ops: ?*const @import("mesh_ops.zig").MeshOps = null,

    // Project root path — set from main.zig when a project is loaded.
    project_root: ?[]const u8 = null,
    scripts_dir: []const u8 = "Content/Scripts",

    pub fn init(allocator: std.mem.Allocator, port: u16) Server {
        return .{
            .allocator = allocator,
            .port = port,
        };
    }

    pub fn deinit(self: *Server) void {
        self.shutdown.store(true, .release);

        // Wait for listener thread
        if (self.listener_thread) |thread| {
            thread.join();
            self.listener_thread = null;
        }

        // Wait for client threads
        for (&self.client_threads) |*slot| {
            if (slot.*) |thread| {
                thread.join();
                slot.* = null;
            }
        }

        // Drain queues
        {
            self.incoming_mutex.lock();
            defer self.incoming_mutex.unlock();
            for (self.incoming.items) |*msg| msg.deinit(self.allocator);
            self.incoming.deinit(self.allocator);
        }
        {
            self.outgoing_mutex.lock();
            defer self.outgoing_mutex.unlock();
            for (self.outgoing.items) |*msg| msg.deinit(self.allocator);
            self.outgoing.deinit(self.allocator);
        }
    }

    /// Start the listener thread. Non-blocking — returns immediately.
    pub fn start(self: *Server) !void {
        self.listener_thread = try std.Thread.spawn(.{}, listenerMain, .{self});
    }

    /// Process pending RPC requests on the main thread (called each frame).
    /// Returns the number of requests processed.
    pub fn processPending(self: *Server, layer_context: *core.LayerContext) !u32 {
        // 1. Drain incoming queue
        var batch: [64]IncomingMessage = undefined;
        var count: u32 = 0;
        {
            self.incoming_mutex.lock();
            defer self.incoming_mutex.unlock();
            const n = @min(self.incoming.items.len, batch.len);
            if (n > 0) {
                @memcpy(batch[0..n], self.incoming.items[0..n]);
                // Remove processed items
                const remaining = self.incoming.items.len - n;
                if (remaining > 0) {
                    std.mem.copyForwards(
                        IncomingMessage,
                        self.incoming.items[0..remaining],
                        self.incoming.items[n..],
                    );
                }
                self.incoming.shrinkRetainingCapacity(remaining);
                count = @intCast(n);
            }
        }

        // 2. Dispatch each request
        for (batch[0..count]) |*msg| {
            defer msg.deinit(self.allocator);

            const response_json = methods.dispatch(self.allocator, msg.payload, layer_context, &self.settings, self.mesh_ops, self.project_root, self.scripts_dir) catch |err| {
                log.warn("RPC dispatch error: {s}", .{@errorName(err)});
                continue;
            };

            if (response_json) |json| {
                self.enqueueOutgoing(msg.client_id, json);
            }
        }

        // 3. Check subscription state changes and broadcast notifications
        try subscriptions.checkAndBroadcast(self, layer_context);

        // 4. Flush outgoing queue to clients
        self.flushOutgoing();

        return count;
    }

    /// Enqueue a response or notification for a specific client (or broadcast if client_id=0).
    pub fn enqueueOutgoing(self: *Server, client_id: u32, payload: []u8) void {
        self.outgoing_mutex.lock();
        defer self.outgoing_mutex.unlock();
        self.outgoing.append(self.allocator, .{
            .client_id = client_id,
            .payload = payload,
        }) catch {
            self.allocator.free(payload);
        };
    }

    /// Broadcast a notification to all connected clients.
    pub fn broadcast(self: *Server, payload: []u8) void {
        self.enqueueOutgoing(0, payload);
    }

    /// Push a console log entry into the ring buffer. Thread-safe.
    pub fn pushConsoleLog(self: *Server, level: []const u8, message: []const u8, source: ?[]const u8) void {
        self.console_log_mutex.lock();
        defer self.console_log_mutex.unlock();
        const idx = (self.console_log_head + self.console_log_count) % max_console_log_entries;
        var entry = &self.console_log_buf[idx];
        const llen: u8 = @intCast(@min(level.len, entry.level.len));
        @memcpy(entry.level[0..llen], level[0..llen]);
        entry.level_len = llen;
        const mlen: u16 = @intCast(@min(message.len, entry.message.len));
        @memcpy(entry.message[0..mlen], message[0..mlen]);
        entry.message_len = mlen;
        if (source) |s| {
            const slen: u8 = @intCast(@min(s.len, entry.source.len));
            @memcpy(entry.source[0..slen], s[0..slen]);
            entry.source_len = slen;
        } else {
            entry.source_len = 0;
        }
        if (self.console_log_count < max_console_log_entries) {
            self.console_log_count += 1;
        } else {
            // Ring buffer full — drop oldest
            self.console_log_head = (self.console_log_head + 1) % max_console_log_entries;
        }
    }

    /// Drain all pending console log entries. Caller must hold no locks.
    pub fn drainConsoleLogs(self: *Server, buf: []ConsoleLogEntry) u32 {
        self.console_log_mutex.lock();
        defer self.console_log_mutex.unlock();
        const n = @min(self.console_log_count, @as(u32, @intCast(buf.len)));
        for (0..n) |i| {
            buf[i] = self.console_log_buf[(self.console_log_head + @as(u32, @intCast(i))) % max_console_log_entries];
        }
        self.console_log_head = (self.console_log_head + n) % max_console_log_entries;
        self.console_log_count -= n;
        return n;
    }

    /// Get the Layer interface for integration with Application.
    pub fn asLayer(self: *Server) core.Layer {
        return .{
            .name = "EditorRpc",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_update = onUpdate,
                .on_detach = onDetach,
            },
        };
    }

    // ── Layer Hooks ──────────────────────────────────────────────────

    fn onAttach(context: *anyopaque, _: *core.LayerContext) !void {
        const self: *Server = @ptrCast(@alignCast(context));
        global_server = self;
        try self.start();
        log.info("Editor RPC server listening on port {d}", .{self.port});
    }

    fn onDetach(context: *anyopaque) void {
        const self: *Server = @ptrCast(@alignCast(context));
        global_server = null;
        self.shutdown.store(true, .release);
        log.info("Editor RPC server shutting down", .{});
    }

    fn onUpdate(context: *anyopaque, layer_context: *core.LayerContext) !void {
        const self: *Server = @ptrCast(@alignCast(context));
        _ = try self.processPending(layer_context);
    }

    // ── Network Threads ──────────────────────────────────────────────

    fn listenerMain(self: *Server) void {
        self.acceptLoop() catch |err| {
            if (!self.shutdown.load(.acquire)) {
                log.err("Listener error: {s}", .{@errorName(err)});
            }
        };
    }

    fn acceptLoop(self: *Server) !void {
        const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, self.port);
        var listener = try address.listen(.{
            .reuse_address = true,
        });
        defer listener.deinit();

        // Print ready message for Electron process to detect
        var stdout_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&stdout_buf, "Editor RPC server listening on port {d}\n", .{self.port}) catch unreachable;
        _ = std.posix.write(std.posix.STDOUT_FILENO, msg) catch {};

        while (!self.shutdown.load(.acquire)) {
            // Non-blocking accept with timeout
            const conn = listener.accept() catch |err| {
                if (self.shutdown.load(.acquire)) return;
                log.warn("Accept error: {s}", .{@errorName(err)});
                continue;
            };

            self.spawnClientHandler(conn.stream) catch |err| {
                log.warn("Failed to spawn client handler: {s}", .{@errorName(err)});
                conn.stream.close();
            };
        }
    }

    fn spawnClientHandler(self: *Server, stream: std.net.Stream) !void {
        // Find a free client slot
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();

        for (&self.clients, &self.client_threads) |*client_slot, *thread_slot| {
            if (client_slot.* == null) {
                const client_id = self.next_client_id;
                self.next_client_id += 1;

                client_slot.* = .{
                    .stream = stream,
                    .alive = true,
                    .id = client_id,
                };

                _ = self.active_client_count.fetchAdd(1, .acq_rel);

                // Join old thread if any
                if (thread_slot.*) |old_thread| {
                    old_thread.join();
                }

                thread_slot.* = try std.Thread.spawn(.{}, clientMain, .{ self, client_id });
                log.info("Client {d} connected", .{client_id});
                return;
            }
        }

        log.warn("Max clients reached, rejecting connection", .{});
        stream.close();
    }

    fn clientMain(self: *Server, client_id: u32) void {
        defer {
            self.removeClient(client_id);
            _ = self.active_client_count.fetchSub(1, .acq_rel);
            log.info("Client {d} disconnected", .{client_id});
        }

        self.clientLoop(client_id) catch |err| {
            if (!self.shutdown.load(.acquire)) {
                log.warn("Client {d} error: {s}", .{ client_id, @errorName(err) });
            }
        };
    }

    fn clientLoop(self: *Server, client_id: u32) !void {
        const stream = self.getClientStream(client_id) orelse return;

        // Perform WebSocket handshake
        try ws.performHandshake(stream);

        while (!self.shutdown.load(.acquire)) {
            const frame = ws.readFrame(self.allocator, stream) catch |err| {
                switch (err) {
                    error.ConnectionClosed => return,
                    else => return err,
                }
            };

            switch (frame.opcode) {
                .text => {
                    // Enqueue for main-thread processing
                    self.incoming_mutex.lock();
                    defer self.incoming_mutex.unlock();
                    self.incoming.append(self.allocator, .{
                        .client_id = client_id,
                        .payload = @constCast(frame.payload),
                    }) catch {
                        self.allocator.free(frame.payload);
                    };
                },
                .close => {
                    ws.writeCloseFrame(stream) catch {};
                    self.allocator.free(frame.payload);
                    return;
                },
                .ping => {
                    ws.writePongFrame(stream, frame.payload) catch {};
                    self.allocator.free(frame.payload);
                },
                else => {
                    self.allocator.free(frame.payload);
                },
            }
        }
    }

    // ── Client Management ────────────────────────────────────────────

    fn getClientStream(self: *Server, client_id: u32) ?std.net.Stream {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (&self.clients) |*slot| {
            if (slot.*) |client| {
                if (client.id == client_id and client.alive) {
                    return client.stream;
                }
            }
        }
        return null;
    }

    fn removeClient(self: *Server, client_id: u32) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (&self.clients) |*slot| {
            if (slot.*) |*client| {
                if (client.id == client_id) {
                    client.alive = false;
                    client.stream.close();
                    slot.* = null;
                    return;
                }
            }
        }
    }

    pub fn flushOutgoing(self: *Server) void {
        var batch_buf: [64]OutgoingMessage = undefined;
        var count: usize = 0;
        {
            self.outgoing_mutex.lock();
            defer self.outgoing_mutex.unlock();
            count = @min(self.outgoing.items.len, batch_buf.len);
            if (count > 0) {
                @memcpy(batch_buf[0..count], self.outgoing.items[0..count]);
                const remaining = self.outgoing.items.len - count;
                if (remaining > 0) {
                    std.mem.copyForwards(
                        OutgoingMessage,
                        self.outgoing.items[0..remaining],
                        self.outgoing.items[count..],
                    );
                }
                self.outgoing.shrinkRetainingCapacity(remaining);
            }
        }

        if (count == 0) return;

        // Snapshot live client handles so we can write outside the mutex.
        const ClientSnapshot = struct { stream: std.net.Stream, alive: bool, id: u32 };
        var snap_buf: [max_clients]?ClientSnapshot = undefined;
        {
            self.clients_mutex.lock();
            defer self.clients_mutex.unlock();
            for (&self.clients, 0..) |*slot, i| {
                if (slot.*) |c| {
                    snap_buf[i] = .{ .stream = c.stream, .alive = c.alive, .id = c.id };
                } else {
                    snap_buf[i] = null;
                }
            }
        }

        // Write to clients WITHOUT holding the mutex
        for (batch_buf[0..count]) |*msg| {
            defer self.allocator.free(msg.payload);

            if (msg.client_id == 0) {
                // Broadcast
                for (&snap_buf) |snap| {
                    if (snap) |c| {
                        if (c.alive) {
                            ws.writeTextFrame(c.stream, msg.payload) catch {};
                        }
                    }
                }
            } else {
                // Targeted send
                for (&snap_buf) |snap| {
                    if (snap) |c| {
                        if (c.id == msg.client_id and c.alive) {
                            ws.writeTextFrame(c.stream, msg.payload) catch {};
                            break;
                        }
                    }
                }
            }
        }
    }
};
