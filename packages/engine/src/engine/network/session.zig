///! Network session — connection management, handshake, player slots.
///!
///! Provides `NetworkSession` which orchestrates the connection lifecycle:
///!
///!   Host mode:  bind + listen → accept connections → manage player slots
///!   Client mode: connect to host → handshake → receive state
///!
///! Connection handshake (4-step):
///!   1. Client → Server: ConnectRequest { client_version }
///!   2. Server → Client: ConnectChallenge { challenge_token }
///!   3. Client → Server: ConnectResponse { challenge_token }
///!   4. Server → Client: ConnectAccepted { player_id } | ConnectDenied { reason }
///!
///! Heartbeat: both sides send periodic heartbeats.  If no packet is received
///! for `TIMEOUT_NS` the peer is considered disconnected.
const std = @import("std");
const protocol = @import("protocol.zig");
const transport_mod = @import("transport.zig");

const log = std.log.scoped(.net_session);

/// Session configuration.
pub const SessionConfig = struct {
    /// Maximum number of connected players (host mode).
    max_players: u8 = 16,
    /// Port to bind (host mode) or 0 for random (client mode).
    port: u16 = 7777,
    /// Heartbeat interval in nanoseconds (500ms).
    heartbeat_interval_ns: i128 = 500_000_000,
    /// Connection timeout in nanoseconds (10s).
    timeout_ns: i128 = 10_000_000_000,
};

/// Unique player identifier (assigned by host, 1-based).
pub const PlayerId = u8;

/// Player slot.
pub const PlayerSlot = struct {
    id: PlayerId,
    address: transport_mod.Address,
    state: PlayerState = .connecting,
    challenge_token: u32 = 0,
    rtt_ms: f32 = 0,
};

pub const PlayerState = enum {
    connecting,
    connected,
    disconnected,
};

/// Session role.
pub const SessionRole = enum {
    none,
    host,
    client,
};

/// Session events (returned by update).
pub const SessionEvent = union(enum) {
    /// A player has connected.
    player_connected: PlayerId,
    /// A player has disconnected.
    player_disconnected: PlayerId,
    /// We successfully connected to the host (client only).
    connected,
    /// Connection to host failed or was denied (client only).
    connection_failed,
    /// Received a game-layer message.
    message: struct {
        from: PlayerId,
        channel: protocol.Channel,
        payload: []const u8,
    },
};

/// Fixed-capacity event buffer.
const MAX_EVENTS: usize = 64;

// ═══════════════════════════════════════════════════════════════════════════
// NetworkSession
// ═══════════════════════════════════════════════════════════════════════════

pub const NetworkSession = struct {
    allocator: std.mem.Allocator,
    config: SessionConfig,
    role: SessionRole = .none,
    transport: ?transport_mod.UdpTransport = null,

    /// Player slots (host keeps all; client keeps only slot 0 = self).
    players: std.ArrayList(PlayerSlot),
    /// Our player ID (assigned by host; 0 means not yet assigned).
    local_player_id: PlayerId = 0,
    /// Host address (client mode only).
    host_address: ?transport_mod.Address = null,
    /// Next player ID to assign (host only).
    next_player_id: PlayerId = 1,
    /// Pending events for this frame.
    events: std.ArrayList(SessionEvent),
    /// Last heartbeat send time.
    last_heartbeat_time: i128 = 0,
    /// Connection attempt start time (client mode).
    connect_start_time: i128 = 0,
    /// Client connection state.
    client_state: ClientState = .idle,

    const ClientState = enum {
        idle,
        sending_request,
        awaiting_challenge,
        sending_response,
        awaiting_accept,
        connected,
        failed,
    };

    pub fn init(allocator: std.mem.Allocator, config: SessionConfig) NetworkSession {
        return .{
            .allocator = allocator,
            .config = config,
            .players = std.ArrayList(PlayerSlot).empty,
            .events = std.ArrayList(SessionEvent).empty,
        };
    }

    pub fn deinit(self: *NetworkSession) void {
        if (self.transport) |*t| t.deinit();
        self.players.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    /// Start hosting a game session.
    pub fn host(self: *NetworkSession) !void {
        if (self.transport != null) return error.AlreadyActive;
        self.transport = try transport_mod.UdpTransport.init(self.allocator, self.config.port);
        self.role = .host;
        self.local_player_id = 0; // Host is player 0
        log.info("hosting on port {}", .{self.config.port});
    }

    /// Connect to a host.
    pub fn connect(self: *NetworkSession, host_addr: transport_mod.Address) !void {
        if (self.transport != null) return error.AlreadyActive;
        // Bind to any available port.
        self.transport = try transport_mod.UdpTransport.init(self.allocator, 0);
        self.role = .client;
        self.host_address = host_addr;
        self.client_state = .sending_request;
        self.connect_start_time = std.time.nanoTimestamp();
        log.info("connecting to host...", .{});
    }

    /// Disconnect and clean up.
    pub fn disconnect(self: *NetworkSession) void {
        if (self.transport) |*t| {
            // Send disconnect to all peers.
            if (self.role == .host) {
                for (self.players.items) |*player| {
                    if (player.state == .connected) {
                        self.sendControl(player.address, .disconnect, &.{}) catch {};
                    }
                }
            } else if (self.host_address) |addr| {
                self.sendControl(addr, .disconnect, &.{}) catch {};
            }
            t.deinit();
        }
        self.transport = null;
        self.role = .none;
        self.client_state = .idle;
        self.players.clearRetainingCapacity();
        self.local_player_id = 0;
        log.info("disconnected", .{});
    }

    /// Tick the session — poll transport, process handshakes, check timeouts.
    /// Returns events that occurred this tick.
    pub fn update(self: *NetworkSession) ![]const SessionEvent {
        self.events.clearRetainingCapacity();

        var t = &(self.transport orelse return self.events.items);
        const now = std.time.nanoTimestamp();

        // Poll incoming packets.
        const packets = try t.poll();

        for (packets) |pkt| {
            switch (pkt.channel) {
                .control => self.handleControl(pkt.from, pkt.payload, now),
                else => {
                    // Game-layer message: find player ID for this address.
                    const player_id = self.playerIdForAddress(pkt.from) orelse continue;
                    self.events.append(self.allocator, .{
                        .message = .{
                            .from = player_id,
                            .channel = pkt.channel,
                            .payload = pkt.payload,
                        },
                    }) catch {};
                },
            }
        }

        // Client: drive handshake state machine.
        if (self.role == .client) {
            self.tickClientHandshake(now);
        }

        // Heartbeat.
        if (now - self.last_heartbeat_time > self.config.heartbeat_interval_ns) {
            self.sendHeartbeats() catch {};
            self.last_heartbeat_time = now;
        }

        // Timeout check.
        self.checkTimeouts(now);

        return self.events.items;
    }

    /// Send a game message to a specific player (host only).
    pub fn sendToPlayer(self: *NetworkSession, player_id: PlayerId, channel: protocol.Channel, payload: []const u8) !void {
        const t = &(self.transport orelse return error.NotConnected);
        if (self.role != .host) return error.NotHost;
        for (self.players.items) |*p| {
            if (p.id == player_id and p.state == .connected) {
                try t.send(p.address, channel, payload);
                return;
            }
        }
    }

    /// Send a game message to all connected players (host only).
    pub fn broadcast(self: *NetworkSession, channel: protocol.Channel, payload: []const u8) !void {
        const t = &(self.transport orelse return error.NotConnected);
        for (self.players.items) |*p| {
            if (p.state == .connected) {
                t.send(p.address, channel, payload) catch {};
            }
        }
    }

    /// Send a game message to host (client only).
    pub fn sendToHost(self: *NetworkSession, channel: protocol.Channel, payload: []const u8) !void {
        const t = &(self.transport orelse return error.NotConnected);
        if (self.role != .client) return error.NotClient;
        const addr = self.host_address orelse return error.NotConnected;
        try t.send(addr, channel, payload);
    }

    /// Get connected player count.
    pub fn connectedPlayerCount(self: *const NetworkSession) u32 {
        var count: u32 = 0;
        for (self.players.items) |*p| {
            if (p.state == .connected) count += 1;
        }
        return count;
    }

    pub fn isConnected(self: *const NetworkSession) bool {
        return switch (self.role) {
            .host => true,
            .client => self.client_state == .connected,
            .none => false,
        };
    }

    // ─── Internal ────────────────────────────────────────────────────────

    fn sendControl(self: *NetworkSession, addr: transport_mod.Address, kind: protocol.ControlKind, payload: []const u8) !void {
        var t = &(self.transport orelse return);
        var buf: [256]u8 = undefined;
        buf[0] = @intFromEnum(kind);
        if (payload.len > 0) {
            @memcpy(buf[1..][0..payload.len], payload);
        }
        try t.send(addr, .control, buf[0 .. 1 + payload.len]);
    }

    fn handleControl(self: *NetworkSession, from: transport_mod.Address, payload: []const u8, now: i128) void {
        _ = now;
        if (payload.len < 1) return;
        const kind = std.meta.intToEnum(protocol.ControlKind, payload[0]) catch return;
        const ctrl_payload = payload[1..];

        switch (self.role) {
            .host => self.handleControlHost(from, kind, ctrl_payload),
            .client => self.handleControlClient(from, kind, ctrl_payload),
            .none => {},
        }
    }

    fn handleControlHost(self: *NetworkSession, from: transport_mod.Address, kind: protocol.ControlKind, payload: []const u8) void {
        switch (kind) {
            .connect_request => {
                if (self.players.items.len >= self.config.max_players) {
                    self.sendControl(from, .connect_denied, &.{}) catch {};
                    return;
                }
                // Generate challenge token.
                const token = @as(u32, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
                var token_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &token_bytes, token, .little);
                self.sendControl(from, .connect_challenge, &token_bytes) catch {};

                // Store pending player.
                self.players.append(self.allocator, .{
                    .id = self.next_player_id,
                    .address = from,
                    .state = .connecting,
                    .challenge_token = token,
                }) catch {};
            },
            .connect_response => {
                if (payload.len < 4) return;
                const token = std.mem.readInt(u32, payload[0..4], .little);

                for (self.players.items) |*player| {
                    if (player.state == .connecting and player.challenge_token == token) {
                        player.state = .connected;
                        // Send accepted.
                        self.sendControl(from, .connect_accepted, &.{player.id}) catch {};
                        self.next_player_id +%= 1;
                        self.events.append(self.allocator, .{ .player_connected = player.id }) catch {};
                        log.info("player {} connected", .{player.id});
                        return;
                    }
                }
                self.sendControl(from, .connect_denied, &.{}) catch {};
            },
            .disconnect => {
                if (self.playerIdForAddress(from)) |pid| {
                    self.disconnectPlayer(pid);
                }
            },
            .heartbeat => {}, // Just keeps the connection alive (recv time updated by transport).
            else => {},
        }
    }

    fn handleControlClient(self: *NetworkSession, _: transport_mod.Address, kind: protocol.ControlKind, payload: []const u8) void {
        switch (kind) {
            .connect_challenge => {
                if (payload.len >= 4 and self.client_state == .awaiting_challenge) {
                    self.client_state = .sending_response;
                    // Echo back the challenge token.
                    self.sendControl(
                        self.host_address.?,
                        .connect_response,
                        payload[0..4],
                    ) catch {};
                    self.client_state = .awaiting_accept;
                }
            },
            .connect_accepted => {
                if (payload.len >= 1 and (self.client_state == .awaiting_accept or self.client_state == .awaiting_challenge)) {
                    self.local_player_id = payload[0];
                    self.client_state = .connected;
                    self.events.append(self.allocator, .connected) catch {};
                    log.info("connected! player_id={}", .{self.local_player_id});
                }
            },
            .connect_denied => {
                self.client_state = .failed;
                self.events.append(self.allocator, .connection_failed) catch {};
                log.info("connection denied", .{});
            },
            .disconnect => {
                self.client_state = .idle;
                self.events.append(self.allocator, .connection_failed) catch {};
            },
            .heartbeat => {},
            else => {},
        }
    }

    fn tickClientHandshake(self: *NetworkSession, now: i128) void {
        // Timeout check.
        if (self.client_state != .connected and self.client_state != .idle and self.client_state != .failed) {
            if (now - self.connect_start_time > self.config.timeout_ns) {
                self.client_state = .failed;
                self.events.append(self.allocator, .connection_failed) catch {};
                return;
            }
        }

        // Send connect request (retry every 500ms).
        if (self.client_state == .sending_request) {
            self.sendControl(self.host_address.?, .connect_request, &.{}) catch {};
            self.client_state = .awaiting_challenge;
        }
    }

    fn sendHeartbeats(self: *NetworkSession) !void {
        if (self.role == .host) {
            for (self.players.items) |*p| {
                if (p.state == .connected) {
                    self.sendControl(p.address, .heartbeat, &.{}) catch {};
                }
            }
        } else if (self.role == .client and self.client_state == .connected) {
            self.sendControl(self.host_address.?, .heartbeat, &.{}) catch {};
        }
    }

    fn checkTimeouts(self: *NetworkSession, now: i128) void {
        const t = &(self.transport orelse return);
        if (self.role == .host) {
            var i: usize = 0;
            while (i < self.players.items.len) {
                const player = &self.players.items[i];
                if (player.state == .connected) {
                    if (t.getPeer(player.address)) |peer| {
                        if (now - peer.last_recv_time > self.config.timeout_ns) {
                            self.disconnectPlayer(player.id);
                            continue; // Don't increment i; item was swapRemove'd.
                        }
                        player.rtt_ms = t.getRttMs(player.address) orelse 0;
                    }
                }
                i += 1;
            }
        } else if (self.role == .client and self.client_state == .connected) {
            if (self.host_address) |addr| {
                if (t.getPeer(addr)) |peer| {
                    if (now - peer.last_recv_time > self.config.timeout_ns) {
                        self.client_state = .idle;
                        self.events.append(self.allocator, .connection_failed) catch {};
                    }
                }
            }
        }
    }

    fn disconnectPlayer(self: *NetworkSession, player_id: PlayerId) void {
        for (self.players.items, 0..) |*p, i| {
            if (p.id == player_id) {
                self.events.append(self.allocator, .{ .player_disconnected = player_id }) catch {};
                log.info("player {} disconnected", .{player_id});
                _ = self.players.swapRemove(i);
                return;
            }
        }
    }

    fn playerIdForAddress(self: *const NetworkSession, addr: transport_mod.Address) ?PlayerId {
        const key = addressKey(addr);
        for (self.players.items) |*p| {
            if (addressKey(p.address) == key) return p.id;
        }
        return null;
    }
};

fn addressKey(addr: transport_mod.Address) u64 {
    switch (addr.any.family) {
        std.posix.AF.INET => {
            const in4: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&addr.any));
            return @as(u64, in4.addr) | (@as(u64, in4.port) << 32);
        },
        else => return 0,
    }
}
