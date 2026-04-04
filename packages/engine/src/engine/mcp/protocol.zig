const std = @import("std");

pub const jsonrpc_version = "2.0";
pub const default_protocol_version = "2025-06-18";

pub const ErrorCode = struct {
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
    pub const resource_not_found: i64 = -32002;
};

pub const ResourceDescriptor = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    size: ?usize = null,
};

pub const ResourceTemplateDescriptor = struct {
    uriTemplate: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

pub const TextResourceContents = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: []const u8,
};

pub fn encodeMessageAlloc(allocator: std.mem.Allocator, payload: anytype) ![]u8 {
    const body = try stringifyAlloc(allocator, payload);
    defer allocator.free(body);

    const header = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{body.len});
    defer allocator.free(header);

    var framed = std.ArrayList(u8).empty;
    defer framed.deinit(allocator);

    try framed.appendSlice(allocator, header);
    try framed.appendSlice(allocator, body);
    return try framed.toOwnedSlice(allocator);
}

pub fn tryExtractMessageAlloc(allocator: std.mem.Allocator, pending: *std.ArrayList(u8)) !?[]u8 {
    const terminator = findHeaderTerminator(pending.items) orelse return null;
    const header_bytes = pending.items[0..terminator.header_end];
    const content_length = parseContentLength(header_bytes) orelse return error.MissingContentLength;
    const total_size = terminator.body_start + content_length;
    if (pending.items.len < total_size) {
        return null;
    }

    const body = try allocator.dupe(u8, pending.items[terminator.body_start..total_size]);
    const remaining = pending.items.len - total_size;
    std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[total_size..]);
    pending.shrinkRetainingCapacity(remaining);
    return body;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(value, .{}, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    return try output.toOwnedSlice(allocator);
}

const HeaderTerminator = struct {
    header_end: usize,
    body_start: usize,
};

fn findHeaderTerminator(bytes: []const u8) ?HeaderTerminator {
    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |index| {
        return .{ .header_end = index, .body_start = index + 4 };
    }
    if (std.mem.indexOf(u8, bytes, "\n\n")) |index| {
        return .{ .header_end = index, .body_start = index + 2 };
    }
    return null;
}

fn parseContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitAny(u8, headers, "\n");
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trimRight(u8, line_with_cr, "\r");
        if (line.len == 0) {
            continue;
        }

        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..separator], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            continue;
        }

        const value_text = std.mem.trim(u8, line[separator + 1 ..], " \t");
        return std.fmt.parseInt(usize, value_text, 10) catch null;
    }
    return null;
}

test "tryExtractMessageAlloc waits for a full framed body" {
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(std.testing.allocator);

    try pending.appendSlice(std.testing.allocator, "Content-Length: 17\r\n\r\n{\"jsonrpc\":\"2.0\"");
    try std.testing.expect(try tryExtractMessageAlloc(std.testing.allocator, &pending) == null);

    try pending.appendSlice(std.testing.allocator, "}");
    const body = (try tryExtractMessageAlloc(std.testing.allocator, &pending)).?;
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}", body);
    try std.testing.expectEqual(@as(usize, 0), pending.items.len);
}

test "tryExtractMessageAlloc consumes multiple messages in order" {
    const first = "Content-Length: 2\r\n\r\n{}";
    const second = "Content-Length: 4\r\n\r\nnull";

    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(std.testing.allocator);
    try pending.appendSlice(std.testing.allocator, first);
    try pending.appendSlice(std.testing.allocator, second);

    const first_body = (try tryExtractMessageAlloc(std.testing.allocator, &pending)).?;
    defer std.testing.allocator.free(first_body);
    try std.testing.expectEqualStrings("{}", first_body);

    const second_body = (try tryExtractMessageAlloc(std.testing.allocator, &pending)).?;
    defer std.testing.allocator.free(second_body);
    try std.testing.expectEqualStrings("null", second_body);
}
