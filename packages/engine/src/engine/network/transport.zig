///! Network transport — non-blocking UDP socket + reliable delivery.
///!
///! Provides `UdpTransport` which wraps a single non-blocking UDP socket and
///! adds per-peer reliable delivery via sequence/ack tracking.  The transport
///! is **not** thread-safe; call `poll()` and `send()` from the same thread
///! (typically the main game loop).
///!
///! Reliable delivery uses the "ack bitfield" scheme:
///!   - Every outgoing packet carries the latest received remote sequence (`ack`)
///!     and a 32-bit bitfield of the 32 sequences before it (`ack_bits`).
///!   - The sender keeps a ring buffer of unacked outgoing packets and
///!     retransmits after a timeout if no ack has been received.
const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");

const log = std.log.scoped(.net_transport);

// ═══════════════════════════════════════════════════════════════════════════
// Address helper
// ═══════════════════════════════════════════════════════════════════════════

pub const Address = std.net.Address;

// ═══════════════════════════════════════════════════════════════════════════
// Sent packet record (for reliable retransmission)
// ═══════════════════════════════════════════════════════════════════════════

const SentPacket = struct {
    sequence: u16,
    send_time: i128, // nanosecond timestamp
    acked: bool = false,
    data: [protocol.MAX_PACKET]u8 = undefined,
    data_len: usize = 0,

    fn isEmpty(self: *const SentPacket) bool {
        return self.data_len == 0;
    }
};

/// Ring buffer size — must be power of 2.
const SEND_BUFFER_SIZE: usize = 256;
const SEND_BUFFER_MASK: usize = SEND_BUFFER_SIZE - 1;

/// Reliable retransmission timeout (nanoseconds): 200ms default.
const RETRANSMIT_NS: i128 = 200_000_000;

// ═══════════════════════════════════════════════════════════════════════════
// Per-peer connection state
// ═══════════════════════════════════════════════════════════════════════════

pub const PeerState = struct {
    address: Address,
    /// Our outgoing sequence counter.
    local_sequence: u16 = 0,
    /// Highest remote sequence received.
    remote_sequence: u16 = 0,
    /// Bitfield: bit N = received (remote_sequence - 1 - N).
    remote_ack_bits: u32 = 0,
    /// Ring buffer of sent reliable packets awaiting ack.
    sent_packets: [SEND_BUFFER_SIZE]SentPacket = [_]SentPacket{SentPacket{ .sequence = 0, .send_time = 0 }} ** SEND_BUFFER_SIZE,
    /// Round-trip time estimate (nanoseconds).
    rtt_ns: i128 = 100_000_000, // 100ms initial estimate
    /// Smoothed RTT (exponential moving average).
    smoothed_rtt_ns: i128 = 100_000_000,
    /// Last time we received any packet from this peer.
    last_recv_time: i128 = 0,
    /// Last time we sent any packet to this peer.
    last_send_time: i128 = 0,
    /// Connection alive.
    connected: bool = true,

    fn nextSequence(self: *PeerState) u16 {
        const seq = self.local_sequence;
        self.local_sequence +%= 1;
        return seq;
    }

    /// Record an incoming packet's sequence number.
    fn recordReceived(self: *PeerState, sequence: u16) void {
        if (protocol.sequenceGreaterThan(sequence, self.remote_sequence)) {
            // New most-recent sequence.
            const diff = protocol.sequenceDiff(sequence, self.remote_sequence);
            if (diff > 0) {
                // Shift ack_bits by the difference.
                if (diff >= 32) {
                    self.remote_ack_bits = 0;
                } else {
                    self.remote_ack_bits <<= @intCast(diff);
                }
                // Set bit 0 for the previously most-recent sequence.
                if (diff <= 32) {
                    self.remote_ack_bits |= (@as(u32, 1) << @intCast(diff - 1));
                }
            }
            self.remote_sequence = sequence;
        } else {
            // Older sequence — set the corresponding bit.
            const diff = protocol.sequenceDiff(self.remote_sequence, sequence);
            if (diff > 0 and diff <= 32) {
                self.remote_ack_bits |= (@as(u32, 1) << @intCast(diff - 1));
            }
        }
    }

    /// Process ack/ack_bits from an incoming packet header. Marks sent packets as acked.
    fn processAcks(self: *PeerState, ack: u16, ack_bits: u32, now: i128) void {
        // The remote side is telling us it received `ack` and the 32 before it.
        self.markAcked(ack, now);
        for (0..32) |i| {
            if ((ack_bits & (@as(u32, 1) << @intCast(i))) != 0) {
                self.markAcked(ack -% @as(u16, @intCast(i + 1)), now);
            }
        }
    }

    fn markAcked(self: *PeerState, sequence: u16, now: i128) void {
        const idx = @as(usize, sequence) & SEND_BUFFER_MASK;
        var sent = &self.sent_packets[idx];
        if (sent.sequence == sequence and !sent.acked and sent.data_len > 0) {
            sent.acked = true;
            // Update RTT.
            const sample = now - sent.send_time;
            if (sample > 0) {
                self.smoothed_rtt_ns = self.smoothed_rtt_ns + @divTrunc(sample - self.smoothed_rtt_ns, 8);
                self.rtt_ns = self.smoothed_rtt_ns;
            }
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Received packet (returned by poll)
// ═══════════════════════════════════════════════════════════════════════════

pub const ReceivedPacket = struct {
    from: Address,
    channel: protocol.Channel,
    payload: []const u8,
};

// ═══════════════════════════════════════════════════════════════════════════
// UdpTransport
// ═══════════════════════════════════════════════════════════════════════════

pub const UdpTransport = struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    /// Peer table keyed by address hash.
    peers: std.AutoHashMap(u64, PeerState),
    /// Reusable receive buffer.
    recv_buf: [protocol.MAX_PACKET]u8 = undefined,
    /// Receive queue (decoded packets from the last poll call).
    recv_queue: std.ArrayList(ReceivedPacket),
    /// Payload storage for recv queue entries.
    recv_payloads: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator, bind_port: u16) !UdpTransport {
        const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, bind_port);

        const sock = try posix.socket(
            posix.AF.INET,
            posix.SOCK.DGRAM | posix.SOCK.NONBLOCK,
            0,
        );
        errdefer posix.close(sock);

        try posix.bind(sock, &addr.any, addr.getOsSockLen());

        return .{
            .allocator = allocator,
            .socket = sock,
            .peers = std.AutoHashMap(u64, PeerState).init(allocator),
            .recv_queue = std.ArrayList(ReceivedPacket).empty,
            .recv_payloads = std.ArrayList([]u8).empty,
        };
    }

    pub fn deinit(self: *UdpTransport) void {
        posix.close(self.socket);
        for (self.recv_payloads.items) |p| self.allocator.free(p);
        self.recv_payloads.deinit(self.allocator);
        self.recv_queue.deinit(self.allocator);
        self.peers.deinit();
    }

    /// Get or create peer state for an address.
    pub fn getOrCreatePeer(self: *UdpTransport, addr: Address) !*PeerState {
        const key = addressKey(addr);
        const result = try self.peers.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = PeerState{
                .address = addr,
                .last_recv_time = std.time.nanoTimestamp(),
            };
        }
        return result.value_ptr;
    }

    pub fn getPeer(self: *UdpTransport, addr: Address) ?*PeerState {
        return self.peers.getPtr(addressKey(addr));
    }

    /// Send a packet to a peer on a given channel.
    pub fn send(self: *UdpTransport, addr: Address, channel: protocol.Channel, payload: []const u8) !void {
        const peer = try self.getOrCreatePeer(addr);
        const now = std.time.nanoTimestamp();
        const seq = peer.nextSequence();

        const header = protocol.PacketHeader{
            .protocol_id = protocol.PROTOCOL_ID,
            .sequence = seq,
            .ack = peer.remote_sequence,
            .ack_bits = peer.remote_ack_bits,
            .channel = @intFromEnum(channel),
            .payload_len = @intCast(payload.len),
        };

        var buf: [protocol.MAX_PACKET]u8 = undefined;
        const total = try protocol.encodePacket(&buf, header, payload);

        // For reliable channel, stash a copy for retransmission.
        if (channel == .reliable or channel == .control) {
            const idx = @as(usize, seq) & SEND_BUFFER_MASK;
            peer.sent_packets[idx] = .{
                .sequence = seq,
                .send_time = now,
                .acked = false,
            };
            @memcpy(peer.sent_packets[idx].data[0..total], buf[0..total]);
            peer.sent_packets[idx].data_len = total;
        }

        _ = posix.sendto(self.socket, buf[0..total], 0, &addr.any, addr.getOsSockLen()) catch |err| {
            log.warn("sendto failed: {}", .{err});
            return;
        };
        peer.last_send_time = now;
    }

    /// Poll the socket for incoming packets.  Returns a slice of received packets.
    /// The returned slice is valid until the next call to `poll()`.
    pub fn poll(self: *UdpTransport) ![]const ReceivedPacket {
        // Clear previous poll results.
        for (self.recv_payloads.items) |p| self.allocator.free(p);
        self.recv_payloads.clearRetainingCapacity();
        self.recv_queue.clearRetainingCapacity();

        const now = std.time.nanoTimestamp();

        // Drain the socket.
        while (true) {
            var src_addr: posix.sockaddr = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

            const n = posix.recvfrom(self.socket, &self.recv_buf, 0, &src_addr, &addr_len) catch |err| {
                if (err == error.WouldBlock) break;
                log.warn("recvfrom error: {}", .{err});
                break;
            };

            if (n == 0) break;

            const decoded = protocol.decodePacket(self.recv_buf[0..n]) catch continue;
            const addr = Address{ .any = src_addr };

            // Update peer state.
            const peer = self.getOrCreatePeer(addr) catch continue;
            peer.last_recv_time = now;
            peer.recordReceived(decoded.header.sequence);
            peer.processAcks(decoded.header.ack, decoded.header.ack_bits, now);

            // Copy payload for the queue.
            const payload_copy = self.allocator.alloc(u8, decoded.payload.len) catch continue;
            @memcpy(payload_copy, decoded.payload);
            self.recv_payloads.append(self.allocator, payload_copy) catch {
                self.allocator.free(payload_copy);
                continue;
            };

            const channel = std.meta.intToEnum(protocol.Channel, decoded.header.channel) catch .unreliable;

            // For unreliable_sequenced, drop if older than last received.
            if (channel == .unreliable_sequenced) {
                if (!protocol.sequenceGreaterThan(decoded.header.sequence, peer.remote_sequence)) {
                    continue;
                }
            }

            self.recv_queue.append(self.allocator, .{
                .from = addr,
                .channel = channel,
                .payload = payload_copy,
            }) catch continue;
        }

        // Retransmit unacked reliable packets.
        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            const peer = entry.value_ptr;
            if (!peer.connected) continue;

            for (&peer.sent_packets) |*sent| {
                if (sent.data_len > 0 and !sent.acked) {
                    if (now - sent.send_time > RETRANSMIT_NS) {
                        // Resend.
                        _ = posix.sendto(
                            self.socket,
                            sent.data[0..sent.data_len],
                            0,
                            &peer.address.any,
                            peer.address.getOsSockLen(),
                        ) catch {};
                        sent.send_time = now; // Reset timer.
                    }
                }
            }
        }

        return self.recv_queue.items;
    }

    /// Get RTT in milliseconds for a peer, or null if peer unknown.
    pub fn getRttMs(self: *UdpTransport, addr: Address) ?f32 {
        const peer = self.getPeer(addr) orelse return null;
        return @as(f32, @floatFromInt(@as(i64, @intCast(@min(peer.rtt_ns, std.math.maxInt(i64)))))) / 1_000_000.0;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Hash an address to a u64 key for the peer table.
fn addressKey(addr: Address) u64 {
    switch (addr.any.family) {
        posix.AF.INET => {
            const in4: *const posix.sockaddr.in = @ptrCast(@alignCast(&addr.any));
            return @as(u64, in4.addr) | (@as(u64, in4.port) << 32);
        },
        posix.AF.INET6 => {
            const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&addr.any));
            var hash: u64 = in6.port;
            const addr_bytes = std.mem.asBytes(&in6.addr);
            for (addr_bytes) |b| {
                hash = hash *% 31 +% b;
            }
            return hash;
        },
        else => return 0,
    }
}
