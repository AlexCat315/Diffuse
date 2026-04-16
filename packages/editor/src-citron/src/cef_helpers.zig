const citron = @import("citron");
const cef = citron.cef;

const CefString = citron.CefString;

pub fn setDictString(dict: *cef.cef_dictionary_value_t, key: []const u8, value: []const u8) void {
    var key_str = CefString.init(key);
    defer key_str.deinit();
    var value_str = CefString.init(value);
    defer value_str.deinit();
    _ = dict.*.set_string.?(dict, key_str.ptr(), value_str.ptr());
}

pub fn setDictBool(dict: *cef.cef_dictionary_value_t, key: []const u8, value: bool) void {
    var key_str = CefString.init(key);
    defer key_str.deinit();
    _ = dict.*.set_bool.?(dict, key_str.ptr(), if (value) 1 else 0);
}

pub fn setDictInt(dict: *cef.cef_dictionary_value_t, key: []const u8, value: i32) void {
    var key_str = CefString.init(key);
    defer key_str.deinit();
    _ = dict.*.set_int.?(dict, key_str.ptr(), value);
}

pub fn setDictDouble(dict: *cef.cef_dictionary_value_t, key: []const u8, value: f64) void {
    var key_str = CefString.init(key);
    defer key_str.deinit();
    _ = dict.*.set_double.?(dict, key_str.ptr(), value);
}

pub fn setDictList(dict: *cef.cef_dictionary_value_t, key: []const u8, list: *cef.cef_list_value_t) void {
    var key_str = CefString.init(key);
    defer key_str.deinit();
    _ = dict.*.set_list.?(dict, key_str.ptr(), list);
}

pub fn newStringValue(value: []const u8) ?*cef.cef_value_t {
    const out = cef.cef_value_create() orelse return null;
    var value_str = CefString.init(value);
    defer value_str.deinit();
    _ = out.*.set_string.?(out, value_str.ptr());
    return out;
}

pub fn newBoolValue(value: bool) ?*cef.cef_value_t {
    const out = cef.cef_value_create() orelse return null;
    _ = out.*.set_bool.?(out, if (value) 1 else 0);
    return out;
}

pub fn wrapDict(dict: *cef.cef_dictionary_value_t) ?*cef.cef_value_t {
    const out = cef.cef_value_create() orelse return null;
    _ = out.*.set_dictionary.?(out, dict);
    _ = dict.*.base.release.?(&dict.*.base);
    return out;
}

pub fn wrapList(list: *cef.cef_list_value_t) ?*cef.cef_value_t {
    const out = cef.cef_value_create() orelse return null;
    _ = out.*.set_list.?(out, list);
    _ = list.*.base.release.?(&list.*.base);
    return out;
}
