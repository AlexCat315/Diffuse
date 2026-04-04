const std = @import("std");

pub const Key = enum(u8) {
    w,
    a,
    s,
    d,
    b,
    i,
    m,
    q,
    e,
    f,
    g,
    r,
    t,
    n,
    tab,
    delete,
    backspace,
    one,
    two,
    three,
    l,
    o,
    p,
    x,
    y,
    z,
    period,
    shift,
    ctrl,
    alt,
    space,
    escape,
    // Directional keys
    up,
    down,
    left,
    right,
    // Function keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const MouseButton = enum(u8) {
    left,
    right,
    middle,
};

pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

const key_count = std.meta.fields(Key).len;
const mouse_button_count = std.meta.fields(MouseButton).len;

/// Gamepad 按钮（对应 SDL3 SDL_GamepadButton 布局）
pub const GamepadButton = enum(u8) {
    south, // A / Cross
    east, // B / Circle
    west, // X / Square
    north, // Y / Triangle
    back, // Select / Share
    guide, // Home / PS
    start, // Start / Options
    left_stick,
    right_stick,
    left_shoulder,
    right_shoulder,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
};

/// Gamepad 轴（对应 SDL3 SDL_GamepadAxis 布局）
pub const GamepadAxis = enum(u8) {
    left_x,
    left_y,
    right_x,
    right_y,
    left_trigger,
    right_trigger,
};

const gamepad_button_count = std.meta.fields(GamepadButton).len;
const gamepad_axis_count = std.meta.fields(GamepadAxis).len;

pub const InputState = struct {
    modifiers: Modifiers = .{},
    mouse_position: [2]f32 = .{ 0.0, 0.0 },
    mouse_delta: [2]f32 = .{ 0.0, 0.0 },
    mouse_wheel: [2]f32 = .{ 0.0, 0.0 },
    last_mouse_wheel: [2]f32 = .{ 0.0, 0.0 },
    last_mouse_wheel_position: [2]f32 = .{ 0.0, 0.0 },
    mouse_wheel_event_count: u64 = 0,
    key_down: [key_count]bool = [_]bool{false} ** key_count,
    key_pressed: [key_count]bool = [_]bool{false} ** key_count,
    key_released: [key_count]bool = [_]bool{false} ** key_count,
    mouse_down: [mouse_button_count]bool = [_]bool{false} ** mouse_button_count,
    mouse_pressed: [mouse_button_count]bool = [_]bool{false} ** mouse_button_count,
    mouse_released: [mouse_button_count]bool = [_]bool{false} ** mouse_button_count,
    mouse_double_clicked: [mouse_button_count]bool = [_]bool{false} ** mouse_button_count,
    // Gamepad
    gamepad_connected: bool = false,
    gamepad_button_down: [gamepad_button_count]bool = [_]bool{false} ** gamepad_button_count,
    gamepad_button_pressed: [gamepad_button_count]bool = [_]bool{false} ** gamepad_button_count,
    gamepad_button_released: [gamepad_button_count]bool = [_]bool{false} ** gamepad_button_count,
    gamepad_axes: [gamepad_axis_count]f32 = [_]f32{0.0} ** gamepad_axis_count,

    pub fn beginFrame(self: *InputState) void {
        @memset(self.key_pressed[0..], false);
        @memset(self.key_released[0..], false);
        @memset(self.mouse_pressed[0..], false);
        @memset(self.mouse_released[0..], false);
        @memset(self.mouse_double_clicked[0..], false);
        @memset(self.gamepad_button_pressed[0..], false);
        @memset(self.gamepad_button_released[0..], false);
        self.mouse_delta = .{ 0.0, 0.0 };
        self.mouse_wheel = .{ 0.0, 0.0 };
    }

    pub fn setModifiers(self: *InputState, modifiers: Modifiers) void {
        self.modifiers = modifiers;
    }

    pub fn setKey(self: *InputState, key: Key, is_down: bool) void {
        const index = @intFromEnum(key);
        const was_down = self.key_down[index];
        if (is_down) {
            if (!was_down) {
                self.key_pressed[index] = true;
            }
        } else if (was_down) {
            self.key_released[index] = true;
        }
        self.key_down[index] = is_down;
    }

    pub fn setMouseButton(self: *InputState, button: MouseButton, is_down: bool, clicks: u8) void {
        const index = @intFromEnum(button);
        const was_down = self.mouse_down[index];
        if (is_down) {
            if (!was_down) {
                self.mouse_pressed[index] = true;
                if (clicks == 2) {
                    self.mouse_double_clicked[index] = true;
                }
            }
        } else if (was_down) {
            self.mouse_released[index] = true;
        }
        self.mouse_down[index] = is_down;
    }

    pub fn updateMousePosition(self: *InputState, x: f32, y: f32) void {
        self.mouse_position = .{ x, y };
    }

    pub fn addMouseDelta(self: *InputState, x: f32, y: f32, delta_x: f32, delta_y: f32) void {
        self.mouse_position = .{ x, y };
        self.mouse_delta[0] += delta_x;
        self.mouse_delta[1] += delta_y;
    }

    pub fn addMouseWheel(self: *InputState, wheel_x: f32, wheel_y: f32) void {
        self.mouse_wheel[0] += wheel_x;
        self.mouse_wheel[1] += wheel_y;
        self.last_mouse_wheel = .{ wheel_x, wheel_y };
        self.last_mouse_wheel_position = self.mouse_position;
        self.mouse_wheel_event_count += 1;
    }

    pub fn isKeyDown(self: *const InputState, key: Key) bool {
        return self.key_down[@intFromEnum(key)];
    }

    pub fn wasKeyPressed(self: *const InputState, key: Key) bool {
        return self.key_pressed[@intFromEnum(key)];
    }

    pub fn wasKeyReleased(self: *const InputState, key: Key) bool {
        return self.key_released[@intFromEnum(key)];
    }

    pub fn isMouseDown(self: *const InputState, button: MouseButton) bool {
        return self.mouse_down[@intFromEnum(button)];
    }

    pub fn wasMousePressed(self: *const InputState, button: MouseButton) bool {
        return self.mouse_pressed[@intFromEnum(button)];
    }

    pub fn wasMouseReleased(self: *const InputState, button: MouseButton) bool {
        return self.mouse_released[@intFromEnum(button)];
    }

    pub fn wasMouseDoubleClicked(self: *const InputState, button: MouseButton) bool {
        return self.mouse_double_clicked[@intFromEnum(button)];
    }

    pub fn cancelMouseButton(self: *InputState, button: MouseButton) void {
        const index = @intFromEnum(button);
        self.mouse_down[index] = false;
        self.mouse_pressed[index] = false;
        self.mouse_released[index] = false;
        self.mouse_double_clicked[index] = false;
    }

    // ── Gamepad ──

    pub fn setGamepadButton(self: *InputState, button: GamepadButton, is_down: bool) void {
        const index = @intFromEnum(button);
        const was_down = self.gamepad_button_down[index];
        if (is_down) {
            if (!was_down) self.gamepad_button_pressed[index] = true;
        } else if (was_down) {
            self.gamepad_button_released[index] = true;
        }
        self.gamepad_button_down[index] = is_down;
    }

    pub fn setGamepadAxis(self: *InputState, axis: GamepadAxis, value: f32) void {
        self.gamepad_axes[@intFromEnum(axis)] = value;
    }

    pub fn isGamepadButtonDown(self: *const InputState, button: GamepadButton) bool {
        return self.gamepad_button_down[@intFromEnum(button)];
    }

    pub fn wasGamepadButtonPressed(self: *const InputState, button: GamepadButton) bool {
        return self.gamepad_button_pressed[@intFromEnum(button)];
    }

    pub fn wasGamepadButtonReleased(self: *const InputState, button: GamepadButton) bool {
        return self.gamepad_button_released[@intFromEnum(button)];
    }

    pub fn getGamepadAxis(self: *const InputState, axis: GamepadAxis) f32 {
        return self.gamepad_axes[@intFromEnum(axis)];
    }
};

test "mouse double click is reported only on the press frame" {
    var input = InputState{};

    input.beginFrame();
    input.setMouseButton(.left, true, 2);
    try std.testing.expect(input.wasMousePressed(.left));
    try std.testing.expect(input.wasMouseDoubleClicked(.left));

    input.beginFrame();
    try std.testing.expect(!input.wasMouseDoubleClicked(.left));

    input.setMouseButton(.left, false, 0);
    try std.testing.expect(input.wasMouseReleased(.left));

    input.beginFrame();
    input.setMouseButton(.left, true, 1);
    try std.testing.expect(input.wasMousePressed(.left));
    try std.testing.expect(!input.wasMouseDoubleClicked(.left));
}

test "mouse triple click is not reported as another double click" {
    var input = InputState{};

    input.beginFrame();
    input.setMouseButton(.left, true, 2);
    try std.testing.expect(input.wasMouseDoubleClicked(.left));

    input.beginFrame();
    input.setMouseButton(.left, false, 0);
    try std.testing.expect(input.wasMouseReleased(.left));

    input.beginFrame();
    input.setMouseButton(.left, true, 3);
    try std.testing.expect(input.wasMousePressed(.left));
    try std.testing.expect(!input.wasMouseDoubleClicked(.left));
}

test "cancelMouseButton clears mouse state without synthesizing release" {
    var input = InputState{};

    input.beginFrame();
    input.setMouseButton(.left, true, 1);
    try std.testing.expect(input.isMouseDown(.left));
    try std.testing.expect(input.wasMousePressed(.left));

    input.cancelMouseButton(.left);
    try std.testing.expect(!input.isMouseDown(.left));
    try std.testing.expect(!input.wasMousePressed(.left));
    try std.testing.expect(!input.wasMouseReleased(.left));
    try std.testing.expect(!input.wasMouseDoubleClicked(.left));
}
