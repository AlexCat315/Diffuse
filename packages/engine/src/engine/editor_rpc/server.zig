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

    // Shared editor settings (viewport, physics viz, camera bookmarks, material preview)
    settings: @import("settings.zig").EditorSettings = .{},

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

            const response_json = methods.dispatch(self.allocator, msg.payload, layer_context, &self.settings) catch |err| {
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
        try self.start();
        log.info("Editor RPC server listening on port {d}", .{self.port});
    }

    fn onDetach(context: *anyopaque) void {
        const self: *Server = @ptrCast(@alignCast(context));
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

    fn flushOutgoing(self: *Server) void {
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

        // Send to clients (outside lock)
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();

        for (batch_buf[0..count]) |*msg| {
            defer self.allocator.free(msg.payload);

            if (msg.client_id == 0) {
                // Broadcast
                for (&self.clients) |*slot| {
                    if (slot.*) |client| {
                        if (client.alive) {
                            ws.writeTextFrame(client.stream, msg.payload) catch {
                                // Client write error — will be cleaned up on next read
                            };
                        }
                    }
                }
            } else {
                // Targeted send
                for (&self.clients) |*slot| {
                    if (slot.*) |client| {
                        if (client.id == msg.client_id and client.alive) {
                            ws.writeTextFrame(client.stream, msg.payload) catch {};
                            break;
                        }
                    }
                }
            }
        }
    }
};
