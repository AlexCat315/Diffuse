///! Minimal RFC 6455 WebSocket server for the editor RPC channel.
///!
///! Handles the HTTP upgrade handshake and WebSocket frame encoding/decoding.
///! Only supports text frames (opcode 0x1) and close frames (opcode 0x8).
///! Designed for trusted localhost connections from the Electron editor.
const std = @import("std");
const io_globals = @import("io_globals");

const log = std.log.scoped(.websocket);

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Frame = struct {
    opcode: Opcode,
    payload: []const u8,
};

/// Perform the WebSocket upgrade handshake on an accepted TCP connection.
/// Returns true if the handshake succeeded, false otherwise.
pub fn performHandshake(stream: std.Io.net.Stream) !void {
    // Read the HTTP request (up to 4KB should be enough for the upgrade request)
    var buf: [4096]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buf.len) {
        const n = streamRead(stream, buf[total_read..]) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        total_read += n;

        // Check if we have the full HTTP request (ends with \r\n\r\n)
        if (std.mem.indexOf(u8, buf[0..total_read], "\r\n\r\n") != null) {
            break;
        }
    }

    const request = buf[0..total_read];

    // Extract Sec-WebSocket-Key header
    const key = extractHeader(request, "Sec-WebSocket-Key") orelse return error.MissingWebSocketKey;

    // Compute accept key: base64(SHA1(key + magic_guid))
    const magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(magic_guid);
    const hash = hasher.finalResult();

    var accept_key: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept_key, &hash);

    // Send HTTP 101 Switching Protocols response
    const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: ";

    try streamWriteAll(stream, response);
    try streamWriteAll(stream, &accept_key);
    try streamWriteAll(stream, "\r\n\r\n");
}

/// Read a single WebSocket frame from the stream.
/// Caller owns the returned payload memory.
pub fn readFrame(allocator: std.mem.Allocator, stream: std.Io.net.Stream) !Frame {
    // Read first 2 bytes: FIN/opcode + mask/payload_len
    var header: [2]u8 = undefined;
    try readExact(stream, &header);

    // FIN bit must be set — we don't support fragmented frames
    if ((header[0] & 0x80) == 0) return error.FragmentedFrameUnsupported;

    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(header[0] & 0x0F)));

    // RFC 6455 §5.1: client-to-server frames MUST be masked
    if ((header[1] & 0x80) == 0) return error.UnmaskedClientFrame;
    var payload_len: u64 = header[1] & 0x7F;

    // Extended payload length
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }

    // Sanity limit: 16 MB per frame
    if (payload_len > 16 * 1024 * 1024) {
        return error.FrameTooLarge;
    }

    // Read masking key (always present per RFC 6455 §5.1)
    var mask_key: [4]u8 = undefined;
    try readExact(stream, &mask_key);

    // Read payload
    const payload = try allocator.alloc(u8, @intCast(payload_len));
    errdefer allocator.free(payload);

    if (payload.len > 0) {
        try readExact(stream, payload);

        // Unmask payload
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask_key[i % 4];
        }
    }

    return .{ .opcode = opcode, .payload = payload };
}

/// Write a WebSocket text frame to the stream.
/// Server frames are never masked per RFC 6455.
pub fn writeTextFrame(stream: std.Io.net.Stream, payload: []const u8) !void {
    // FIN=1, opcode=text
    var header_buf: [10]u8 = undefined;
    var header_len: usize = 2;
    header_buf[0] = 0x81; // FIN + text opcode

    if (payload.len < 126) {
        header_buf[1] = @intCast(payload.len);
    } else if (payload.len <= 65535) {
        header_buf[1] = 126;
        std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header_buf[1] = 127;
        std.mem.writeInt(u64, header_buf[2..10], @intCast(payload.len), .big);
        header_len = 10;
    }

    try streamWriteAll(stream, header_buf[0..header_len]);
    if (payload.len > 0) {
        try streamWriteAll(stream, payload);
    }
}

/// Write a WebSocket close frame.
pub fn writeCloseFrame(stream: std.Io.net.Stream) !void {
    const frame = [_]u8{ 0x88, 0x00 }; // FIN + close, zero payload
    try streamWriteAll(stream, &frame);
}

/// Write a WebSocket pong frame with the given payload.
pub fn writePongFrame(stream: std.Io.net.Stream, payload: []const u8) !void {
    var header_buf: [2]u8 = undefined;
    header_buf[0] = 0x8A; // FIN + pong
    header_buf[1] = @intCast(@min(payload.len, 125));

    try streamWriteAll(stream, &header_buf);
    if (payload.len > 0 and payload.len <= 125) {
        try streamWriteAll(stream, payload[0..@min(payload.len, 125)]);
    }
}

// ── Helpers ──────────────────────────────────────────────────────

fn readExact(stream: std.Io.net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = streamRead(stream, buf[total..]) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}

/// Read from a net.Stream handle.
fn streamRead(stream: std.Io.net.Stream, buf: []u8) !usize {
    var reader_buffer: [0]u8 = undefined;
    var reader = stream.reader(io_globals.global_io, &reader_buffer);
    return reader.interface.readSliceShort(buf);
}

/// Write all bytes to a net.Stream handle, retrying on partial writes.
fn streamWriteAll(stream: std.Io.net.Stream, data: []const u8) !void {
    var writer_buffer: [0]u8 = undefined;
    var writer = stream.writer(io_globals.global_io, &writer_buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn extractHeader(request: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    while (lines.next()) |line| {
        if (line.len > name.len + 2 and std.ascii.eqlIgnoreCase(line[0..name.len], name)) {
            if (line[name.len] == ':') {
                const value = std.mem.trimStart(u8, line[name.len + 1 ..], " ");
                return std.mem.trimEnd(u8, value, " \r\n");
            }
        }
    }
    return null;
}
