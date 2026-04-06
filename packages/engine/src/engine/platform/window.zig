const std = @import("std");
const builtin = @import("builtin");
const input_mod = @import("../core/input.zig");
const sdl = @import("sdl.zig").c;

extern fn guava_window_apply_macos_native_titlebar_style(window: *sdl.SDL_Window) bool;
extern fn guava_window_macos_titlebar_leading_inset(window: *sdl.SDL_Window) f32;
extern fn guava_window_activate_macos_app() void;
extern fn guava_window_set_background_app() void;
extern fn guava_window_begin_macos_native_drag(window: *sdl.SDL_Window) bool;
extern fn guava_window_apply_windows_native_titlebar_style(window: *sdl.SDL_Window) bool;
extern fn guava_window_windows_titlebar_trailing_inset(window: *sdl.SDL_Window) f32;
extern fn guava_window_create_metal_layer_binding(window_handle: *anyopaque, out_binding: *MetalLayerBinding) bool;
extern fn guava_window_destroy_metal_layer_binding(binding: MetalLayerBinding) void;
extern fn guava_window_get_native_win32_hwnd(window_handle: *anyopaque) ?*anyopaque;
extern fn guava_window_get_native_cocoa_window(window_handle: *anyopaque) ?*anyopaque;
extern fn guava_window_attach_to_parent_nsview(child_sdl_window: *anyopaque, parent_nsview: *anyopaque) bool;
extern fn guava_window_detach_from_parent(child_sdl_window: *anyopaque) bool;

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const MetalLayerBinding = extern struct {
    metal_view: ?*anyopaque,
    layer: ?*anyopaque,
};

pub const WindowConfig = struct {
    title: []const u8 = "Guava Engine",
    width: u32 = 0,
    height: u32 = 0,
    resizable: bool = true,
    borderless: bool = false,
    maximized: bool = false,
    native_titlebar_controls: bool = true,
    high_pixel_density: bool = true,
    hidden: bool = false,
    /// On macOS, hide the process from the Dock and Cmd-Tab switcher.
    /// Must be set at creation time (before the window appears).
    background_app: bool = false,
};

pub const EventKind = enum {
    quit_requested,
    close_requested,
    resized,
    pixel_size_changed,
    metal_view_resized,
    exposed,
    mouse_button_down,
    mouse_button_up,
    mouse_moved,
    mouse_wheel,
    key_down,
    key_up,
    text_input,
    gamepad_button_down,
    gamepad_button_up,
    gamepad_axis_motion,
    gamepad_added,
    gamepad_removed,
    file_drop,
};

pub const Event = struct {
    kind: EventKind,
    raw: sdl.SDL_Event = undefined,
    width: u32 = 0,
    height: u32 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    delta_x: f32 = 0.0,
    delta_y: f32 = 0.0,
    clicks: u8 = 0,
    button: ?input_mod.MouseButton = null,
    key: ?input_mod.Key = null,
    repeat: bool = false,
    modifiers: input_mod.Modifiers = .{},
    gamepad_button: ?input_mod.GamepadButton = null,
    gamepad_axis: ?input_mod.GamepadAxis = null,
    axis_value: f32 = 0.0,
    dropped_file_path: ?[:0]const u8 = null,
};

pub const Window = struct {
    handle: *sdl.SDL_Window,
    logical_width: u32 = 0,
    logical_height: u32 = 0,
    drawable_width: u32 = 0,
    drawable_height: u32 = 0,
    content_scale: f32 = 1.0,
    native_titlebar_controls: bool = false,
    native_titlebar_leading_inset: f32 = 0.0,
    native_titlebar_trailing_inset: f32 = 0.0,
    should_close: bool = false,

    // Saved bounds for maximizeFull / restore pair. When the user triggers the
    // explicit fullscreen/usable-area maximize (maximizeFull), we save the
    // previous window position and size here so restore() can put the window
    // back to its previous bounds.
    prev_bounds_valid: bool = false,
    prev_bounds_pos: [2]i32 = .{ 0, 0 },
    prev_bounds_size: [2]i32 = .{ 0, 0 },

    pub fn init(allocator: std.mem.Allocator, config: WindowConfig) !Window {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_GAMEPAD)) {
            std.log.err("SDL_Init failed: {s}", .{lastError()});
            return error.SdlInitFailed;
        }
        errdefer sdl.SDL_Quit();

        // On macOS, hide from Dock/Cmd-Tab BEFORE the window is created so the
        // app never flickers into the Dock.  Must happen after SDL_Init (which
        // creates NSApp) but before SDL_CreateWindow.
        if (config.background_app) {
            setBackgroundApp();
        }

        const title_z = try allocator.dupeZ(u8, config.title);
        defer allocator.free(title_z);

        const use_native_titlebar_controls = config.native_titlebar_controls and switch (builtin.os.tag) {
            .macos, .windows => true,
            else => false,
        };

        var target_width = config.width;
        var target_height = config.height;
        if (target_width == 0 or target_height == 0) {
            const bounds = try primaryDisplayUsableBounds();
            target_width = @intCast(@divTrunc(bounds.w * 85, 100));
            target_height = @intCast(@divTrunc(bounds.h * 85, 100));
        }

        var flags: sdl.SDL_WindowFlags = 0;
        if (config.resizable) {
            flags |= sdl.SDL_WINDOW_RESIZABLE;
        }
        if (config.borderless and !use_native_titlebar_controls) {
            flags |= sdl.SDL_WINDOW_BORDERLESS;
        }
        if (config.high_pixel_density) {
            flags |= sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        }
        if (config.hidden) {
            flags |= sdl.SDL_WINDOW_HIDDEN;
        }
        if (config.maximized) {
            flags |= sdl.SDL_WINDOW_MAXIMIZED;
        }

        const handle = sdl.SDL_CreateWindow(
            title_z.ptr,
            @intCast(target_width),
            @intCast(target_height),
            flags,
        );
        if (handle == null) {
            std.log.err("SDL_CreateWindow failed: {s}", .{lastError()});
            return error.SdlWindowCreateFailed;
        }
        errdefer sdl.SDL_DestroyWindow(handle.?);

        var window = Window{
            .handle = handle.?,
            .native_titlebar_controls = use_native_titlebar_controls,
        };
        if (use_native_titlebar_controls) {
            switch (builtin.os.tag) {
                .macos => {
                    if (!guava_window_apply_macos_native_titlebar_style(window.handle)) {
                        return error.SdlWindowOperationFailed;
                    }
                },
                .windows => {
                    if (!guava_window_apply_windows_native_titlebar_style(window.handle)) {
                        return error.SdlWindowOperationFailed;
                    }
                },
                else => unreachable,
            }
            window.refreshNativeTitlebarInsets();
        }
        if (!config.maximized) {
            try window.positionInUsableBounds(target_width, target_height);
        }
        try window.refreshSizes();

        // Bring window to front
        _ = sdl.SDL_RaiseWindow(window.handle);
        if (config.maximized) {
            // On macOS, SDL_WINDOW_MAXIMIZED may not fully fill the usable area.
            // Explicitly maximize after creation to ensure it covers the full screen
            // below the menu bar and above the dock.
            _ = sdl.SDL_MaximizeWindow(window.handle);
            try window.refreshSizes();
        }
        // Bring window to front — skipped in background-app mode because
        // calling [NSApp activate] on an NSApplicationActivationPolicyAccessory
        // app can cause macOS to briefly flash a Dock icon.
        if (builtin.os.tag == .macos and !config.background_app) {
            guava_window_activate_macos_app();
        }

        return window;
    }

    pub fn deinit(self: *Window) void {
        sdl.SDL_DestroyWindow(self.handle);
        sdl.SDL_Quit();
    }

    /// On macOS, hide the app from the Dock and Cmd-Tab switcher.
    /// Useful for editor-server mode where the engine is a background process.
    pub fn setBackgroundApp() void {
        if (comptime builtin.os.tag == .macos) {
            guava_window_set_background_app();
        }
    }

    pub fn refreshSizes(self: *Window) !void {
        var logical_w: c_int = 0;
        var logical_h: c_int = 0;
        if (!sdl.SDL_GetWindowSize(self.handle, &logical_w, &logical_h)) {
            std.log.err("SDL_GetWindowSize failed: {s}", .{lastError()});
            return error.SdlQueryFailed;
        }

        var drawable_w: c_int = 0;
        var drawable_h: c_int = 0;
        if (!sdl.SDL_GetWindowSizeInPixels(self.handle, &drawable_w, &drawable_h)) {
            std.log.err("SDL_GetWindowSizeInPixels failed: {s}", .{lastError()});
            return error.SdlQueryFailed;
        }

        self.logical_width = @intCast(@max(logical_w, 0));
        self.logical_height = @intCast(@max(logical_h, 0));
        self.drawable_width = @intCast(@max(drawable_w, 0));
        self.drawable_height = @intCast(@max(drawable_h, 0));

        // Calculate content scale factor for UI scaling
        if (self.logical_width > 0) {
            self.content_scale = @as(f32, @floatFromInt(self.drawable_width)) / @as(f32, @floatFromInt(self.logical_width));
        }

        self.refreshNativeTitlebarInsets();
    }

    pub fn pollEvent(self: *Window) !?Event {
        var raw_event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&raw_event)) {
            switch (raw_event.type) {
                sdl.SDL_EVENT_QUIT => {
                    self.should_close = true;
                    return .{ .kind = .quit_requested, .raw = raw_event };
                },
                sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    self.should_close = true;
                    return .{ .kind = .close_requested, .raw = raw_event };
                },
                sdl.SDL_EVENT_WINDOW_RESIZED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .resized,
                        .raw = raw_event,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .pixel_size_changed,
                        .raw = raw_event,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_WINDOW_METAL_VIEW_RESIZED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .metal_view_resized,
                        .raw = raw_event,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_WINDOW_EXPOSED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .exposed,
                        .raw = raw_event,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (raw_event.button.down) {
                        const button = mouseButtonFromSdl(raw_event.button.button) orelse continue;
                        return .{
                            .kind = .mouse_button_down,
                            .raw = raw_event,
                            .x = raw_event.button.x,
                            .y = raw_event.button.y,
                            .clicks = raw_event.button.clicks,
                            .button = button,
                            .modifiers = currentModifiers(),
                        };
                    }
                },
                sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                    if (!raw_event.button.down) {
                        const button = mouseButtonFromSdl(raw_event.button.button) orelse continue;
                        return .{
                            .kind = .mouse_button_up,
                            .raw = raw_event,
                            .x = raw_event.button.x,
                            .y = raw_event.button.y,
                            .clicks = raw_event.button.clicks,
                            .button = button,
                            .modifiers = currentModifiers(),
                        };
                    }
                },
                sdl.SDL_EVENT_MOUSE_MOTION => {
                    return .{
                        .kind = .mouse_moved,
                        .raw = raw_event,
                        .x = raw_event.motion.x,
                        .y = raw_event.motion.y,
                        .delta_x = raw_event.motion.xrel,
                        .delta_y = raw_event.motion.yrel,
                        .modifiers = currentModifiers(),
                    };
                },
                sdl.SDL_EVENT_MOUSE_WHEEL => {
                    const direction_sign: f32 = if (raw_event.wheel.direction == sdl.SDL_MOUSEWHEEL_FLIPPED) -1.0 else 1.0;
                    const wheel_x = if (@abs(raw_event.wheel.x) > 0.0001)
                        raw_event.wheel.x
                    else
                        @as(f32, @floatFromInt(raw_event.wheel.integer_x));
                    const wheel_y = if (@abs(raw_event.wheel.y) > 0.0001)
                        raw_event.wheel.y
                    else
                        @as(f32, @floatFromInt(raw_event.wheel.integer_y));
                    return .{
                        .kind = .mouse_wheel,
                        .raw = raw_event,
                        .x = raw_event.wheel.mouse_x,
                        .y = raw_event.wheel.mouse_y,
                        .delta_x = wheel_x * direction_sign,
                        .delta_y = wheel_y * direction_sign,
                        .modifiers = currentModifiers(),
                    };
                },
                sdl.SDL_EVENT_KEY_DOWN => {
                    return .{
                        .kind = .key_down,
                        .raw = raw_event,
                        .key = keyFromScancode(raw_event.key.scancode),
                        .repeat = raw_event.key.repeat,
                        .modifiers = currentModifiers(),
                    };
                },
                sdl.SDL_EVENT_KEY_UP => {
                    return .{
                        .kind = .key_up,
                        .raw = raw_event,
                        .key = keyFromScancode(raw_event.key.scancode),
                        .repeat = false,
                        .modifiers = currentModifiers(),
                    };
                },
                sdl.SDL_EVENT_TEXT_INPUT, sdl.SDL_EVENT_TEXT_EDITING => {
                    return .{
                        .kind = .text_input,
                        .raw = raw_event,
                    };
                },
                sdl.SDL_EVENT_DROP_FILE => {
                    const c_path: [*c]const u8 = if (raw_event.drop.data != null) raw_event.drop.data else raw_event.drop.source;
                    if (c_path == null) continue;
                    const path_slice = std.mem.sliceTo(c_path, 0);
                    const file_path = try std.heap.c_allocator.dupeZ(u8, path_slice);
                    return .{
                        .kind = .file_drop,
                        .raw = raw_event,
                        .dropped_file_path = file_path,
                    };
                },
                sdl.SDL_EVENT_GAMEPAD_ADDED => {
                    const id = raw_event.gdevice.which;
                    _ = sdl.SDL_OpenGamepad(id);
                    return .{ .kind = .gamepad_added, .raw = raw_event };
                },
                sdl.SDL_EVENT_GAMEPAD_REMOVED => {
                    return .{ .kind = .gamepad_removed, .raw = raw_event };
                },
                sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN => {
                    return .{
                        .kind = .gamepad_button_down,
                        .raw = raw_event,
                        .gamepad_button = gamepadButtonFromSdl(raw_event.gbutton.button),
                    };
                },
                sdl.SDL_EVENT_GAMEPAD_BUTTON_UP => {
                    return .{
                        .kind = .gamepad_button_up,
                        .raw = raw_event,
                        .gamepad_button = gamepadButtonFromSdl(raw_event.gbutton.button),
                    };
                },
                sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION => {
                    return .{
                        .kind = .gamepad_axis_motion,
                        .raw = raw_event,
                        .gamepad_axis = gamepadAxisFromSdl(raw_event.gaxis.axis),
                        .axis_value = @as(f32, @floatFromInt(raw_event.gaxis.value)) / 32767.0,
                    };
                },
                else => {},
            }
        }

        return null;
    }

    pub fn delay(_: *Window, milliseconds: u32) void {
        sdl.SDL_Delay(milliseconds);
    }

    pub fn displayRefreshRate(self: *const Window) ?f32 {
        const display_id = sdl.SDL_GetDisplayForWindow(self.handle);
        if (display_id == 0) {
            return null;
        }

        const current_mode = sdl.SDL_GetCurrentDisplayMode(display_id);
        if (current_mode != null and current_mode[0].refresh_rate > 0.0) {
            return current_mode[0].refresh_rate;
        }

        const desktop_mode = sdl.SDL_GetDesktopDisplayMode(display_id);
        if (desktop_mode != null and desktop_mode[0].refresh_rate > 0.0) {
            return desktop_mode[0].refresh_rate;
        }

        return null;
    }

    pub fn setTitle(self: *Window, allocator: std.mem.Allocator, title: []const u8) !void {
        const title_z = try allocator.dupeZ(u8, title);
        defer allocator.free(title_z);
        _ = sdl.SDL_SetWindowTitle(self.handle, title_z.ptr);
    }

    pub fn position(self: *const Window) ![2]i32 {
        var x: c_int = 0;
        var y: c_int = 0;
        if (!sdl.SDL_GetWindowPosition(self.handle, &x, &y)) {
            std.log.err("SDL_GetWindowPosition failed: {s}", .{lastError()});
            return error.SdlQueryFailed;
        }
        return .{ @intCast(x), @intCast(y) };
    }

    pub fn setPosition(self: *Window, x: i32, y: i32) !void {
        if (!sdl.SDL_SetWindowPosition(self.handle, x, y)) {
            std.log.err("SDL_SetWindowPosition failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
    }

    pub fn globalMousePosition(_: *const Window) [2]f32 {
        var x: f32 = 0.0;
        var y: f32 = 0.0;
        _ = sdl.SDL_GetGlobalMouseState(&x, &y);
        return .{ x, y };
    }

    pub fn beginNativeDrag(self: *Window) bool {
        return switch (builtin.os.tag) {
            .macos => guava_window_begin_macos_native_drag(self.handle),
            else => false,
        };
    }

    /// 启用/禁用相对鼠标模式。
    /// 相对模式下光标隐藏并锁定，鼠标增量不受屏幕边缘限制。
    /// 用于摄像机拖拽（轨道/自由视角），防止移动到屏幕边缘后卡住。
    pub fn setRelativeMouseMode(self: *Window, enabled: bool) void {
        _ = sdl.SDL_SetWindowRelativeMouseMode(self.handle, enabled);
    }

    pub fn minimize(self: *Window) !void {
        if (!sdl.SDL_MinimizeWindow(self.handle)) {
            std.log.err("SDL_MinimizeWindow failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
    }

    pub fn maximize(self: *Window) !void {
        if (!sdl.SDL_MaximizeWindow(self.handle)) {
            std.log.err("SDL_MaximizeWindow failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
    }

    pub fn maximizeFull(self: *Window) !void {
        // Save previous bounds so restore() can return to them.
        // Only overwrite saved bounds if we don't already have a saved state;
        // this prevents clobbering the original bounds if maximizeFull is called
        // repeatedly before a restore.
        if (!self.prev_bounds_valid) {
            const pos = try self.position();
            self.prev_bounds_pos = pos;
            // Use logical width/height as the size we will restore to.
            self.prev_bounds_size = .{
                @intCast(@max(self.logical_width, 1)),
                @intCast(@max(self.logical_height, 1)),
            };
            self.prev_bounds_valid = true;
        }

        // Ensure the window fills the entire usable display area (work area).
        const usable = try primaryDisplayUsableBounds();
        // Set position and size explicitly to usable bounds.
        if (!sdl.SDL_SetWindowPosition(self.handle, usable.x, usable.y)) {
            std.log.err("SDL_SetWindowPosition failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
        if (!sdl.SDL_SetWindowSize(self.handle, usable.w, usable.h)) {
            std.log.err("SDL_SetWindowSize failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
        try self.refreshSizes();
    }

    pub fn restore(self: *Window) !void {
        // If we previously maximized via maximizeFull and saved bounds, restore
        // to those exact bounds instead of relying on SDL_RestoreWindow, which
        // may not map to the saved bounds we expect.
        if (self.prev_bounds_valid) {
            const px = self.prev_bounds_pos[0];
            const py = self.prev_bounds_pos[1];
            const pw = self.prev_bounds_size[0];
            const ph = self.prev_bounds_size[1];

            if (!sdl.SDL_SetWindowPosition(self.handle, px, py)) {
                std.log.err("SDL_SetWindowPosition (restore) failed: {s}", .{lastError()});
                return error.SdlWindowOperationFailed;
            }
            if (!sdl.SDL_SetWindowSize(self.handle, pw, ph)) {
                std.log.err("SDL_SetWindowSize (restore) failed: {s}", .{lastError()});
                return error.SdlWindowOperationFailed;
            }

            // Clear saved bounds after a successful restore.
            self.prev_bounds_valid = false;
            try self.refreshSizes();
            return;
        }

        // Fallback to SDL's restore if we don't have saved bounds.
        if (!sdl.SDL_RestoreWindow(self.handle)) {
            std.log.err("SDL_RestoreWindow failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
    }

    pub fn sync(self: *Window) !void {
        if (!sdl.SDL_SyncWindow(self.handle)) {
            std.log.err("SDL_SyncWindow failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
    }

    pub fn createMetalLayerBinding(self: *Window) ?MetalLayerBinding {
        return switch (builtin.os.tag) {
            .macos => blk: {
                var binding = MetalLayerBinding{
                    .metal_view = null,
                    .layer = null,
                };
                if (!guava_window_create_metal_layer_binding(@ptrCast(self.handle), &binding)) {
                    break :blk null;
                }
                break :blk binding;
            },
            else => null,
        };
    }

    pub fn nativeWin32Hwnd(self: *Window) ?*anyopaque {
        return switch (builtin.os.tag) {
            .windows => guava_window_get_native_win32_hwnd(@ptrCast(self.handle)),
            else => null,
        };
    }

    pub fn nativeCocoaWindow(self: *Window) ?*anyopaque {
        return switch (builtin.os.tag) {
            .macos => guava_window_get_native_cocoa_window(@ptrCast(self.handle)),
            else => null,
        };
    }

    /// Attach this window as a child of the given parent (identified by native view handle).
    /// On macOS, parent_handle should be an NSView*. The child moves with the parent
    /// and stays above it in z-order.
    pub fn attachToParent(self: *Window, parent_handle: *anyopaque) bool {
        return switch (builtin.os.tag) {
            .macos => guava_window_attach_to_parent_nsview(@ptrCast(self.handle), parent_handle),
            else => false,
        };
    }

    /// Detach this window from its parent, making it an independent top-level window again.
    pub fn detachFromParent(self: *Window) bool {
        return switch (builtin.os.tag) {
            .macos => guava_window_detach_from_parent(@ptrCast(self.handle)),
            else => false,
        };
    }

    pub fn isMaximized(self: *const Window) bool {
        return (sdl.SDL_GetWindowFlags(self.handle) & sdl.SDL_WINDOW_MAXIMIZED) != 0;
    }

    pub fn isMaximizedFull(self: *const Window) bool {
        // Return true if the window is currently maximized via maximizeFull().
        // We track maximizeFull state by whether we have saved previous bounds
        // (prev_bounds_valid). This lets the UI distinguish between an OS/native
        // maximize and our explicit "usable-bounds" maximize.
        return self.prev_bounds_valid;
    }

    pub fn usableBounds(_: *const Window) !Rect {
        return primaryDisplayUsableBounds();
    }

    pub fn hasNativeTitlebarControls(self: *const Window) bool {
        return self.native_titlebar_controls;
    }

    pub fn titlebarLeadingInset(self: *const Window) f32 {
        return self.native_titlebar_leading_inset;
    }

    pub fn titlebarTrailingInset(self: *const Window) f32 {
        return self.native_titlebar_trailing_inset;
    }

    pub fn requestClose(self: *Window) void {
        self.should_close = true;
    }

    fn positionInUsableBounds(self: *Window, width: u32, height: u32) !void {
        const usable_bounds = primaryDisplayUsableBounds() catch return;

        const window_width: i32 = @intCast(width);
        const window_height: i32 = @intCast(height);
        const usable_width = @max(usable_bounds.w, window_width);
        const usable_height = @max(usable_bounds.h, window_height);
        const target_x = usable_bounds.x + @divTrunc(usable_width - window_width, 2);
        const target_y = usable_bounds.y + @divTrunc(usable_height - window_height, 2);
        try self.setPosition(target_x, target_y);
    }

    fn refreshNativeTitlebarInsets(self: *Window) void {
        if (!self.native_titlebar_controls) {
            self.native_titlebar_leading_inset = 0.0;
            self.native_titlebar_trailing_inset = 0.0;
            return;
        }

        switch (builtin.os.tag) {
            .macos => {
                self.native_titlebar_leading_inset = guava_window_macos_titlebar_leading_inset(self.handle);
                self.native_titlebar_trailing_inset = 0.0;
            },
            .windows => {
                self.native_titlebar_leading_inset = 0.0;
                self.native_titlebar_trailing_inset = guava_window_windows_titlebar_trailing_inset(self.handle);
            },
            else => {
                self.native_titlebar_leading_inset = 0.0;
                self.native_titlebar_trailing_inset = 0.0;
            },
        }
    }
};

fn primaryDisplayUsableBounds() !Rect {
    const display = sdl.SDL_GetPrimaryDisplay();
    if (display == 0) {
        return error.SdlQueryFailed;
    }

    var usable_bounds: sdl.SDL_Rect = undefined;
    if (!sdl.SDL_GetDisplayUsableBounds(display, &usable_bounds)) {
        std.log.warn("SDL_GetDisplayUsableBounds failed: {s}", .{lastError()});
        return error.SdlQueryFailed;
    }

    return .{
        .x = usable_bounds.x,
        .y = usable_bounds.y,
        .w = usable_bounds.w,
        .h = usable_bounds.h,
    };
}

pub fn lastError() []const u8 {
    return std.mem.sliceTo(sdl.SDL_GetError(), 0);
}

pub fn destroyMetalLayerBinding(binding: MetalLayerBinding) void {
    if (builtin.os.tag == .macos and binding.metal_view != null) {
        guava_window_destroy_metal_layer_binding(binding);
    }
}

fn currentModifiers() input_mod.Modifiers {
    const mods = sdl.SDL_GetModState();
    return .{
        .shift = (mods & sdl.SDL_KMOD_SHIFT) != 0,
        .ctrl = (mods & sdl.SDL_KMOD_CTRL) != 0,
        .alt = (mods & sdl.SDL_KMOD_ALT) != 0,
        .super = (mods & sdl.SDL_KMOD_GUI) != 0,
    };
}

fn mouseButtonFromSdl(button: u8) ?input_mod.MouseButton {
    return switch (button) {
        sdl.SDL_BUTTON_LEFT => .left,
        sdl.SDL_BUTTON_RIGHT => .right,
        sdl.SDL_BUTTON_MIDDLE => .middle,
        else => null,
    };
}

fn keyFromScancode(scancode: c_uint) ?input_mod.Key {
    return switch (scancode) {
        sdl.SDL_SCANCODE_W => .w,
        sdl.SDL_SCANCODE_A => .a,
        sdl.SDL_SCANCODE_S => .s,
        sdl.SDL_SCANCODE_D => .d,
        sdl.SDL_SCANCODE_B => .b,
        sdl.SDL_SCANCODE_I => .i,
        sdl.SDL_SCANCODE_M => .m,
        sdl.SDL_SCANCODE_Q => .q,
        sdl.SDL_SCANCODE_E => .e,
        sdl.SDL_SCANCODE_F => .f,
        sdl.SDL_SCANCODE_G => .g,
        sdl.SDL_SCANCODE_R => .r,
        sdl.SDL_SCANCODE_TAB => .tab,
        sdl.SDL_SCANCODE_DELETE => .delete,
        sdl.SDL_SCANCODE_BACKSPACE => .backspace,
        sdl.SDL_SCANCODE_1 => .one,
        sdl.SDL_SCANCODE_2 => .two,
        sdl.SDL_SCANCODE_3 => .three,
        sdl.SDL_SCANCODE_L => .l,
        sdl.SDL_SCANCODE_O => .o,
        sdl.SDL_SCANCODE_P => .p,
        sdl.SDL_SCANCODE_X => .x,
        sdl.SDL_SCANCODE_Y => .y,
        sdl.SDL_SCANCODE_Z => .z,
        sdl.SDL_SCANCODE_PERIOD => .period,
        sdl.SDL_SCANCODE_LSHIFT, sdl.SDL_SCANCODE_RSHIFT => .shift,
        sdl.SDL_SCANCODE_LCTRL, sdl.SDL_SCANCODE_RCTRL => .ctrl,
        sdl.SDL_SCANCODE_LALT, sdl.SDL_SCANCODE_RALT => .alt,
        sdl.SDL_SCANCODE_SPACE => .space,
        sdl.SDL_SCANCODE_ESCAPE => .escape,
        // Directional keys
        sdl.SDL_SCANCODE_UP => .up,
        sdl.SDL_SCANCODE_DOWN => .down,
        sdl.SDL_SCANCODE_LEFT => .left,
        sdl.SDL_SCANCODE_RIGHT => .right,
        // Function keys
        sdl.SDL_SCANCODE_F1 => .f1,
        sdl.SDL_SCANCODE_F2 => .f2,
        sdl.SDL_SCANCODE_F3 => .f3,
        sdl.SDL_SCANCODE_F4 => .f4,
        sdl.SDL_SCANCODE_F5 => .f5,
        sdl.SDL_SCANCODE_F6 => .f6,
        sdl.SDL_SCANCODE_F7 => .f7,
        sdl.SDL_SCANCODE_F8 => .f8,
        sdl.SDL_SCANCODE_F9 => .f9,
        sdl.SDL_SCANCODE_F10 => .f10,
        sdl.SDL_SCANCODE_F11 => .f11,
        sdl.SDL_SCANCODE_F12 => .f12,
        else => null,
    };
}

fn gamepadButtonFromSdl(button: u8) ?input_mod.GamepadButton {
    return switch (button) {
        sdl.SDL_GAMEPAD_BUTTON_SOUTH => .south,
        sdl.SDL_GAMEPAD_BUTTON_EAST => .east,
        sdl.SDL_GAMEPAD_BUTTON_WEST => .west,
        sdl.SDL_GAMEPAD_BUTTON_NORTH => .north,
        sdl.SDL_GAMEPAD_BUTTON_BACK => .back,
        sdl.SDL_GAMEPAD_BUTTON_GUIDE => .guide,
        sdl.SDL_GAMEPAD_BUTTON_START => .start,
        sdl.SDL_GAMEPAD_BUTTON_LEFT_STICK => .left_stick,
        sdl.SDL_GAMEPAD_BUTTON_RIGHT_STICK => .right_stick,
        sdl.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER => .left_shoulder,
        sdl.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER => .right_shoulder,
        sdl.SDL_GAMEPAD_BUTTON_DPAD_UP => .dpad_up,
        sdl.SDL_GAMEPAD_BUTTON_DPAD_DOWN => .dpad_down,
        sdl.SDL_GAMEPAD_BUTTON_DPAD_LEFT => .dpad_left,
        sdl.SDL_GAMEPAD_BUTTON_DPAD_RIGHT => .dpad_right,
        else => null,
    };
}

fn gamepadAxisFromSdl(axis: u8) ?input_mod.GamepadAxis {
    return switch (axis) {
        sdl.SDL_GAMEPAD_AXIS_LEFTX => .left_x,
        sdl.SDL_GAMEPAD_AXIS_LEFTY => .left_y,
        sdl.SDL_GAMEPAD_AXIS_RIGHTX => .right_x,
        sdl.SDL_GAMEPAD_AXIS_RIGHTY => .right_y,
        sdl.SDL_GAMEPAD_AXIS_LEFT_TRIGGER => .left_trigger,
        sdl.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER => .right_trigger,
        else => null,
    };
}
