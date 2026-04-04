const std = @import("std");
const message_id_mod = @import("message_id.zig");
const types = @import("types.zig");
const en_us = @import("locales/en_us.zig");
const zh_cn = @import("locales/zh_cn.zig");

pub const Language = types.Language;
pub const LocaleInfo = types.LocaleInfo;
pub const TranslationTable = types.TranslationTable;
pub const MessageId = message_id_mod.MessageId;
pub const available_languages = [_]Language{ .en_us, .zh_cn };
pub const default_language: Language = .en_us;
pub const TextId = MessageId;

const locale_map = std.EnumArray(Language, LocaleInfo).init(.{
    .en_us = en_us.locale,
    .zh_cn = zh_cn.locale,
});

pub fn locale(language: Language) *const LocaleInfo {
    return locale_map.getPtrConst(language);
}

pub fn text(language: Language, id: MessageId) []const u8 {
    if (locale(language).translations.get(id)) |value| {
        return value;
    }
    return locale(default_language).translations.get(id).?;
}

pub fn allocPrintMessage(
    comptime id: MessageId,
    allocator: std.mem.Allocator,
    language: Language,
    args: anytype,
) ![]u8 {
    return switch (language) {
        .en_us => std.fmt.allocPrint(allocator, en_us.locale.translations.get(id).?, args),
        .zh_cn => std.fmt.allocPrint(
            allocator,
            zh_cn.locale.translations.get(id) orelse en_us.locale.translations.get(id).?,
            args,
        ),
    };
}

pub fn bufPrintMessage(
    buffer: []u8,
    comptime id: MessageId,
    language: Language,
    args: anytype,
) ![]u8 {
    return switch (language) {
        .en_us => std.fmt.bufPrint(buffer, en_us.locale.translations.get(id).?, args),
        .zh_cn => std.fmt.bufPrint(
            buffer,
            zh_cn.locale.translations.get(id) orelse en_us.locale.translations.get(id).?,
            args,
        ),
    };
}

pub fn panelLabel(language: Language, buffer: []u8, id: MessageId, stable_id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}###{s}", .{ text(language, id), stable_id });
}
