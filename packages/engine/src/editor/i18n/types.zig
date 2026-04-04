const std = @import("std");
const MessageId = @import("message_id.zig").MessageId;

pub const Language = enum {
    en_us,
    zh_cn,
};

pub const TranslationTable = std.EnumArray(MessageId, ?[]const u8);

pub const LocaleInfo = struct {
    language: Language,
    code: []const u8,
    english_name: []const u8,
    native_name: []const u8,
    translations: TranslationTable,
};
