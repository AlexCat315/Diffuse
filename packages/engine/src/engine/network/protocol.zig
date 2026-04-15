///! Network protocol — packet format, sequence numbers, ack bitfield.
///!
///! Implements a lightweight reliable-UDP protocol inspired by Glenn Fiedler's
///! "Game Networking" series.  Each packet carries a header with:
///!
///!   - protocol_id  (4 bytes) — magic number to reject garbage
///!   - sequence      (u16)    — per-connection monotonic counter
///!   - ack           (u16)    — last received remote sequence
///!   - ack_bits      (u32)    — bitfield of 32 received sequences before `ack`
///!   - channel        (u8)    — virtual channel (reliable / unreliable / sequenced)
///!   - payload_len   (u16)    — length of the payload that follows
///!
///! Total header size: 13 bytes.
const std = @import("std");

/// Magic number at the start of every packet (reject non-Guava traffic).
pub const PROTOCOL_ID: u32 = 0x47564E54; // "GVNT"

/// Maximum payload size that fits in a single UDP datagram (conservative).
pub const MAX_PAYLOAD: u16 = 1200;

/// Maximum total packet size (header + payload).
pub const MAX_PACKET: usize = 15 + MAX_PAYLOAD;

/// Virtual channel types.
pub const Channel = enum(u8) {
    /// Reliable ordered — retransmitted until ACKed.
    reliable = 0,
    /// Unreliable — fire-and-forget, no retransmission.
    unreliable = 1,
    /// Unreliable sequenced — newer-sequence-only, drop stale.
    unreliable_sequenced = 2,
    /// Connection control (handshake, heartbeat, disconnect).
    control = 255,
};

/// Control message sub-types.
pub const ControlKind = enum(u8) {
    connect_request = 1,
    connect_challenge = 2,
    connect_response = 3,
    connect_accepted = 4,
    connect_denied = 5,
    heartbeat = 10,
    disconnect = 20,
};

/// Packet header — 13 bytes on the wire.
/// We use a plain struct and manual encode/decode to avoid extern padding.
pub const PacketHeader = struct {
    protocol_id: u32 = PROTOCOL_ID,
    sequence: u16 = 0,
    ack: u16 = 0,
    ack_bits: u32 = 0,
    channel: u8 = 0,
    payload_len: u16 = 0,
};

pub const HEADER_SIZE: usize = 13;

fn writeU16(buf: []u8, v: u16) void {
    buf[0] = @truncate(v);
    buf[1] = @truncate(v >> 8);
}
fn writeU32(buf: []u8, v: u32) void {
    buf[0] = @truncate(v);
    buf[1] = @truncate(v >> 8);
    buf[2] = @truncate(v >> 16);
    buf[3] = @truncate(v >> 24);
}
fn readU16(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}
fn readU32(buf: []const u8) u32 {
    return @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) | (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24);
}

fn encodeHeader(buf: []u8, h: PacketHeader) void {
    writeU32(buf[0..4], h.protocol_id);
    writeU16(buf[4..6], h.sequence);
    writeU16(buf[6..8], h.ack);
    writeU32(buf[8..12], h.ack_bits);
    buf[12] = h.channel;
    writeU16(buf[13..15], h.payload_len);
}

fn decodeHeader(buf: []const u8) PacketHeader {
    return .{
        .protocol_id = readU32(buf[0..4]),
        .sequence = readU16(buf[4..6]),
        .ack = readU16(buf[6..8]),
        .ack_bits = readU32(buf[8..12]),
        .channel = buf[12],
        .payload_len = readU16(buf[13..15]),
    };
}

/// Encode a packet header + payload into `buf`.  Returns the total bytes written.
pub fn encodePacket(
    buf: []u8,
    header: PacketHeader,
    payload: []const u8,
) error{BufferTooSmall}!usize {
    const total = HEADER_SIZE + payload.len;
    if (buf.len < total) return error.BufferTooSmall;

    // Wire format: 13 bytes header + payload_len stored at offset 13.
    // We actually need 15 bytes for the header to store payload_len at [13..15].
    if (buf.len < 15 + payload.len) return error.BufferTooSmall;
    encodeHeader(buf, header);
    if (payload.len > 0) {
        @memcpy(buf[15..][0..payload.len], payload);
    }
    return 15 + payload.len;
}

/// Decode a packet header from raw bytes.  Returns the header and a slice to the payload.
pub fn decodePacket(data: []const u8) error{InvalidPacket}!struct { header: PacketHeader, payload: []const u8 } {
    if (data.len < 15) return error.InvalidPacket;

    const header = decodeHeader(data);

    if (header.protocol_id != PROTOCOL_ID) return error.InvalidPacket;

    const payload_end = 15 + @as(usize, header.payload_len);
    if (data.len < payload_end) return error.InvalidPacket;

    return .{
        .header = header,
        .payload = data[15..payload_end],
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Sequence arithmetic (wrapping u16)
// ═══════════════════════════════════════════════════════════════════════════

/// Returns true if `s1` is "more recent" than `s2`, handling wrap-around.
pub fn sequenceGreaterThan(s1: u16, s2: u16) bool {
    return ((s1 > s2) and (s1 -% s2 <= 32768)) or
        ((s1 < s2) and (s2 -% s1 > 32768));
}

/// Returns the signed difference: s1 - s2 (wrapping).
pub fn sequenceDiff(s1: u16, s2: u16) i32 {
    const diff: i32 = @as(i32, s1) - @as(i32, s2);
    if (diff > 32768) return diff - 65536;
    if (diff < -32768) return diff + 65536;
    return diff;
}

// ═══════════════════════════════════════════════════════════════════════════
// Message types (serialized into payload)
// ═══════════════════════════════════════════════════════════════════════════

/// Top-level message type tag.
pub const MessageKind = enum(u8) {
    /// Entity state snapshot (server → client).
    entity_state = 1,
    /// Player input (client → server).
    player_input = 2,
    /// RPC call.
    rpc = 3,
    /// Entity spawn notification.
    entity_spawn = 4,
    /// Entity despawn notification.
    entity_despawn = 5,
    /// Custom game message (raw bytes, interpreted by scripts).
    custom = 255,
};

/// Write a u8 tag + arbitrary payload into a buffer (simple message framing).
pub fn writeMessage(buf: []u8, kind: MessageKind, payload: []const u8) error{BufferTooSmall}!usize {
    const total = 1 + payload.len;
    if (buf.len < total) return error.BufferTooSmall;
    buf[0] = @intFromEnum(kind);
    if (payload.len > 0) {
        @memcpy(buf[1..][0..payload.len], payload);
    }
    return total;
}

/// Read a message tag + payload slice from raw data.
pub fn readMessage(data: []const u8) error{InvalidPacket}!struct { kind: MessageKind, payload: []const u8 } {
    if (data.len < 1) return error.InvalidPacket;
    const kind = std.enums.fromInt(MessageKind, data[0]) orelse return error.InvalidPacket;
    return .{ .kind = kind, .payload = data[1..] };
}
