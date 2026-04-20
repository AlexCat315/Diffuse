///! Network ECS system — entity replication, state sync.
///!
///! Provides `NetworkSystem` which drives the NetworkSession from the main
///! loop and handles entity state serialization / deserialization.
///!
///! ## Main loop integration
///!
///! Call `net_system.update(&world, delta_seconds)` once per frame, after
///! physics and before scripts.
const std = @import("std");
const session_mod = @import("session.zig");
const protocol = @import("protocol.zig");
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");

const log = std.log.scoped(.net_system);

// ═══════════════════════════════════════════════════════════════════════════
// Network components (stored on Entity)
// ═══════════════════════════════════════════════════════════════════════════

/// Marks an entity for network replication.
pub const NetworkIdentity = struct {
    /// Unique network ID (assigned by host, globally unique within the session).
    network_id: u32 = 0,
    /// Authority model.
    authority: Authority = .server,
    /// Owner player ID (for owner-authoritative entities).
    owner_player_id: session_mod.PlayerId = 0,
    /// Has the initial state been sent?
    spawned: bool = false,
    /// Sync interval (seconds). 0 = every frame.
    sync_interval: f32 = 0.05, // 20 Hz default
    /// Time since last sync.
    time_since_sync: f32 = 0,
    /// Is this entity enabled for networking?
    enabled: bool = true,
};

pub const Authority = enum(u8) {
    /// Server decides the authoritative state (default).
    server = 0,
    /// The owning client has authority over this entity.
    owner = 1,
};

/// Syncs entity transform over the network with interpolation.
pub const NetworkTransform = struct {
    /// Interpolation speed (0 = snap, higher = smoother but more latency).
    interpolation_speed: f32 = 15.0,
    /// Whether to sync position (XYZ).
    sync_position: bool = true,
    /// Whether to sync rotation (quaternion).
    sync_rotation: bool = true,
    /// Whether to sync scale (XYZ).
    sync_scale: bool = false,
    /// Target state received from network.
    target_position: [3]f32 = .{ 0, 0, 0 },
    target_rotation: [4]f32 = .{ 0, 0, 0, 1 },
    target_scale: [3]f32 = .{ 1, 1, 1 },
    /// Is this component enabled?
    enabled: bool = true,
};

// ═══════════════════════════════════════════════════════════════════════════
// Serialization helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Compact transform snapshot for network transmission.
/// 3 * 4 + 4 * 4 + 3 * 4 = 40 bytes for full translation + rotation(quat) + scale.
const TransformSnapshot = extern struct {
    translation: [3]f32 align(1),
    rotation: [4]f32 align(1),
    scale: [3]f32 align(1),
};

/// Entity state packet: network_id (u32) + TransformSnapshot.
const EntityStateSize: usize = @sizeOf(u32) + @sizeOf(TransformSnapshot);

// ═══════════════════════════════════════════════════════════════════════════
// NetworkSystem
// ═══════════════════════════════════════════════════════════════════════════

pub const NetworkSystem = struct {
    session: session_mod.NetworkSession,
    next_network_id: u32 = 1,
    /// Network ID → Entity ID mapping.
    net_to_entity: std.AutoHashMap(u32, scene_mod.EntityId),
    /// Serialization buffer.
    send_buf: [1200]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, config: session_mod.SessionConfig) NetworkSystem {
        return .{
            .session = session_mod.NetworkSession.init(allocator, config),
            .net_to_entity = std.AutoHashMap(u32, scene_mod.EntityId).init(allocator),
        };
    }

    pub fn deinit(self: *NetworkSystem) void {
        self.session.deinit();
        self.net_to_entity.deinit();
    }

    /// Start hosting.
    pub fn host(self: *NetworkSystem) !void {
        try self.session.host();
    }

    /// Connect to a host by IP and port.
    pub fn connect(self: *NetworkSystem, ip: [4]u8, port: u16) !void {
        const addr = std.net.Address.initIp4(ip, port);
        try self.session.connect(addr);
    }

    pub fn disconnect(self: *NetworkSystem) void {
        self.session.disconnect();
        self.net_to_entity.clearRetainingCapacity();
    }

    pub fn isHost(self: *const NetworkSystem) bool {
        return self.session.role == .host;
    }

    pub fn isConnected(self: *const NetworkSystem) bool {
        return self.session.isConnected();
    }

    /// Per-frame update.  Must be called from the main loop.
    pub fn update(self: *NetworkSystem, world: *scene_mod.World, delta_seconds: f32) !void {
        // 1. Tick session (poll packets, handle handshakes).
        const events = try self.session.update();

        // 2. Process session events.
        for (events) |event| {
            switch (event) {
                .player_connected => |pid| {
                    log.info("player {} joined", .{pid});
                    // Host: send current world state to new player.
                    if (self.isHost()) {
                        self.sendFullState(world) catch |err| {
                            log.warn("failed to send full state: {}", .{err});
                        };
                    }
                },
                .player_disconnected => |pid| {
                    log.info("player {} left", .{pid});
                },
                .connected => {
                    log.info("connected to host", .{});
                },
                .connection_failed => {
                    log.warn("connection failed", .{});
                },
                .message => |msg| {
                    self.handleMessage(world, msg.from, msg.payload);
                },
            }
        }

        // 3. Host: broadcast entity state updates.
        if (self.isHost()) {
            self.syncEntityStates(world, delta_seconds) catch |err| {
                log.warn("sync entity states failed: {}", .{err});
            };
        }

        // 4. Client: interpolate remote entity transforms.
        if (!self.isHost() and self.isConnected()) {
            self.interpolateTransforms(world, delta_seconds);
        }
    }

    // ─── Internal ────────────────────────────────────────────────────

    fn assignNetworkId(self: *NetworkSystem, entity_id: scene_mod.EntityId) u32 {
        const nid = self.next_network_id;
        self.next_network_id += 1;
        self.net_to_entity.put(nid, entity_id) catch {};
        return nid;
    }

    fn syncEntityStates(self: *NetworkSystem, world: *scene_mod.World, delta: f32) !void {
        for (world.entities.items) |*entity| {
            var net_id_comp = entity.network_identity orelse continue;
            if (!net_id_comp.enabled) continue;

            // Assign network ID if not yet assigned.
            if (net_id_comp.network_id == 0) {
                net_id_comp.network_id = self.assignNetworkId(entity.id);
                entity.network_identity = net_id_comp;
            }

            // Check sync interval.
            net_id_comp.time_since_sync += delta;
            if (net_id_comp.time_since_sync < net_id_comp.sync_interval) {
                entity.network_identity = net_id_comp;
                continue;
            }
            net_id_comp.time_since_sync = 0;
            entity.network_identity = net_id_comp;

            // Serialize transform.
            const transform = entity.local_transform;
            var buf: [EntityStateSize]u8 = undefined;
            std.mem.writeInt(u32, buf[0..4], net_id_comp.network_id, .little);
            const snapshot = TransformSnapshot{
                .translation = transform.translation,
                .rotation = transform.rotation,
                .scale = transform.scale,
            };
            @memcpy(buf[4..][0..@sizeOf(TransformSnapshot)], std.mem.asBytes(&snapshot));

            // Wrap in message.
            var msg_buf: [1 + EntityStateSize]u8 = undefined;
            const msg_len = protocol.writeMessage(&msg_buf, .entity_state, &buf) catch continue;

            // Broadcast.
            self.session.broadcast(.unreliable, msg_buf[0..msg_len]) catch {};
        }
    }

    fn sendFullState(self: *NetworkSystem, world: *scene_mod.World) !void {
        for (world.entities.items) |*entity| {
            const net_id_comp = entity.network_identity orelse continue;
            if (!net_id_comp.enabled or net_id_comp.network_id == 0) continue;

            // Send spawn + transform.
            var buf: [5 + EntityStateSize]u8 = undefined;
            std.mem.writeInt(u32, buf[0..4], net_id_comp.network_id, .little);
            buf[4] = 0; // Spawn flags (reserved).
            const transform = entity.local_transform;
            const snapshot = TransformSnapshot{
                .translation = transform.translation,
                .rotation = transform.rotation,
                .scale = transform.scale,
            };
            @memcpy(buf[5..][0..@sizeOf(TransformSnapshot)], std.mem.asBytes(&snapshot));

            var msg_buf: [1 + buf.len]u8 = undefined;
            const msg_len = protocol.writeMessage(&msg_buf, .entity_spawn, &buf) catch continue;
            self.session.broadcast(.reliable, msg_buf[0..msg_len]) catch {};
        }
    }

    fn handleMessage(self: *NetworkSystem, world: *scene_mod.World, _: session_mod.PlayerId, payload: []const u8) void {
        const msg = protocol.readMessage(payload) catch return;
        switch (msg.kind) {
            .entity_state => self.handleEntityState(world, msg.payload),
            .entity_spawn => self.handleEntitySpawn(msg.payload),
            .entity_despawn => self.handleEntityDespawn(msg.payload),
            else => {},
        }
    }

    fn handleEntityState(self: *NetworkSystem, world: *scene_mod.World, data: []const u8) void {
        if (data.len < EntityStateSize) return;
        const net_id = std.mem.readInt(u32, data[0..4], .little);
        const snapshot: *const TransformSnapshot = @ptrCast(@alignCast(data[4..][0..@sizeOf(TransformSnapshot)]));

        const entity_id = self.net_to_entity.get(net_id) orelse return;
        const entity = world.getEntity(entity_id) orelse return;

        // Update NetworkTransform target (will be interpolated).
        if (entity.network_transform) |*nt| {
            if (nt.sync_position) nt.target_position = snapshot.translation;
            if (nt.sync_rotation) nt.target_rotation = snapshot.rotation;
            if (nt.sync_scale) nt.target_scale = snapshot.scale;
        } else {
            // No NetworkTransform component — snap directly.
            entity.local_transform.translation = snapshot.translation;
            entity.local_transform.rotation = snapshot.rotation;
            entity.local_transform.scale = snapshot.scale;
            world.markDirty(entity_id);
        }
    }

    fn handleEntitySpawn(self: *NetworkSystem, data: []const u8) void {
        if (data.len < 5) return;
        const net_id = std.mem.readInt(u32, data[0..4], .little);
        // Just register the mapping; actual entity creation happens via scene sync.
        _ = self.net_to_entity.getOrPut(net_id) catch return;
    }

    fn handleEntityDespawn(self: *NetworkSystem, data: []const u8) void {
        if (data.len < 4) return;
        const net_id = std.mem.readInt(u32, data[0..4], .little);
        _ = self.net_to_entity.remove(net_id);
    }

    fn interpolateTransforms(_: *NetworkSystem, world: *scene_mod.World, delta: f32) void {
        for (world.entities.items) |*entity| {
            const nt = entity.network_transform orelse continue;
            if (!nt.enabled) continue;

            var changed = false;
            const t = nt.interpolation_speed * delta;
            const lerp_factor = @min(t, 1.0);

            if (nt.sync_position) {
                const pos = &entity.local_transform.translation;
                inline for (0..3) |axis| {
                    pos[axis] += (nt.target_position[axis] - pos[axis]) * lerp_factor;
                }
                changed = true;
            }
            if (nt.sync_rotation) {
                const rot = &entity.local_transform.rotation;
                inline for (0..4) |axis| {
                    rot[axis] += (nt.target_rotation[axis] - rot[axis]) * lerp_factor;
                }
                changed = true;
            }
            if (nt.sync_scale) {
                const scl = &entity.local_transform.scale;
                inline for (0..3) |axis| {
                    scl[axis] += (nt.target_scale[axis] - scl[axis]) * lerp_factor;
                }
                changed = true;
            }

            if (changed) {
                world.markDirty(entity.id);
            }
        }
    }
};
