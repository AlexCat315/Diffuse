# Script API (`@import("guava")`)

> Source: [`src/engine/script/script_api.zig`](../../src/engine/script/script_api.zig)

User scripts placed in `assets/scripts/` (or any asset path) are compiled to dynamic libraries
and loaded at runtime. Scripts import the engine API via `@import("guava")`.

## Lifecycle Exports

Scripts export C-ABI functions that the engine calls at the appropriate time:

```zig
// Required — engine binds API context before every callback
export fn guava_bind(api: *const guava.HostApi, ctx: ?*anyopaque, entity_id: u64) callconv(.c) void;

// Optional lifecycle callbacks
export fn guava_on_init() callconv(.c) void;
export fn guava_on_update(dt: f32) callconv(.c) void;
export fn guava_on_destroy() callconv(.c) void;

// Optional physics callbacks
export fn guava_on_collision_enter(other_entity: u64) callconv(.c) void;
export fn guava_on_collision_exit(other_entity: u64) callconv(.c) void;
export fn guava_on_trigger_enter(other_entity: u64) callconv(.c) void;
export fn guava_on_trigger_exit(other_entity: u64) callconv(.c) void;
```

> `guava_bind` is auto-generated from `script_api.zig` — user scripts do **not** need to implement it manually.

---

## Types

```zig
pub const Vec3 = [3]f32;
pub const Quat = [4]f32;          // XYZW
pub const AudioClipHandle = u32;  // 0 = invalid
pub const VoiceHandle = u32;      // 0 = invalid
pub const WidgetId = u32;         // 0 = invalid
```

---

## Entity

| Function | Signature | Description |
|----------|-----------|-------------|
| `entityId` | `() u64` | ID of the entity this script is attached to |
| `findEntityByName` | `(name: []const u8) u64` | Lookup by name; returns `0` if not found |
| `spawnEntity` | `() u64` | Create a new empty entity |
| `destroyEntity` | `(id: u64) void` | Destroy an entity by ID |

---

## Transform

| Function | Signature | Description |
|----------|-----------|-------------|
| `getPosition` | `() Vec3` | Local position of the bound entity |
| `setPosition` | `(pos: Vec3) void` | Set local position |
| `getRotation` | `() Quat` | Local rotation (XYZW quaternion) |
| `setRotation` | `(rot: Quat) void` | Set local rotation |
| `getScale` | `() Vec3` | Local scale |
| `setScale` | `(scale: Vec3) void` | Set local scale |

---

## Input — Keyboard

| Function | Signature | Description |
|----------|-----------|-------------|
| `isKeyDown` | `(key: Key) bool` | Is key currently held? |
| `wasKeyPressed` | `(key: Key) bool` | Was key pressed this frame? (edge) |
| `wasKeyReleased` | `(key: Key) bool` | Was key released this frame? (edge) |

### `Key` enum

```
w a s d b i m q e f g r t n
tab delete backspace
one two three
l o p x y z period
shift ctrl alt space escape
up down left right
f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
```

---

## Input — Mouse

| Function | Signature | Description |
|----------|-----------|-------------|
| `isMouseButtonDown` | `(button: MouseButton) bool` | Is button held? |
| `getMousePosition` | `() [2]f32` | Screen-space cursor position |
| `getMouseDelta` | `() [2]f32` | Frame-to-frame cursor movement |
| `getMouseWheel` | `() [2]f32` | Scroll wheel delta (x, y) |

### `MouseButton` enum

`left`, `right`, `middle`

---

## Input — Gamepad

| Function | Signature | Description |
|----------|-----------|-------------|
| `isGamepadConnected` | `() bool` | Any gamepad detected? |
| `isGamepadButtonDown` | `(button: GamepadButton) bool` | Is button held? |
| `wasGamepadButtonPressed` | `(button: GamepadButton) bool` | Pressed this frame? |
| `getGamepadAxis` | `(axis: GamepadAxis) f32` | Axis value (−1..1, triggers 0..1) |

### `GamepadButton` enum

```
south east west north
back guide start
left_stick right_stick left_shoulder right_shoulder
dpad_up dpad_down dpad_left dpad_right
```

### `GamepadAxis` enum

```
left_x left_y right_x right_y left_trigger right_trigger
```

---

## Time

| Function | Signature | Description |
|----------|-----------|-------------|
| `deltaTime` | `() f32` | Frame delta time in seconds |
| `time` | `() f32` | Total elapsed time in seconds |

---

## Physics

| Function | Signature | Description |
|----------|-----------|-------------|
| `raycast` | `(origin: Vec3, direction: Vec3, max_distance: f32) ?RaycastHit` | Closest hit along ray |
| `setLinearVelocity` | `(entity_id: u64, velocity: Vec3) void` | Set rigidbody linear velocity |
| `getLinearVelocity` | `(entity_id: u64) Vec3` | Get rigidbody linear velocity |
| `addImpulse` | `(entity_id: u64, impulse: Vec3) void` | Apply impulse to rigidbody |

### `RaycastHit`

```zig
pub const RaycastHit = struct {
    position: Vec3,   // World-space hit point
    distance: f32,    // Distance from origin
    entity_id: u64,   // Entity that was hit
};
```

---

## Scene

| Function | Signature | Description |
|----------|-----------|-------------|
| `loadScene` | `(path: []const u8) void` | Load a scene file (async) |

---

## Audio

| Function | Signature | Description |
|----------|-----------|-------------|
| `audioLoadClip` | `(path: []const u8) AudioClipHandle` | Load audio clip from file; `0` = failed |
| `audioPlay2d` | `(clip: AudioClipHandle, volume: f32, loop: bool) VoiceHandle` | Play 2D sound |
| `audioPlay3d` | `(clip: AudioClipHandle, pos: Vec3, volume: f32, loop: bool) VoiceHandle` | Play 3D spatial sound |
| `audioStop` | `(voice: VoiceHandle) void` | Stop a voice |
| `audioSetVolume` | `(voice: VoiceHandle, volume: f32) void` | Adjust volume |
| `audioPause` | `(voice: VoiceHandle, paused: bool) void` | Pause / resume |
| `audioIsPlaying` | `(voice: VoiceHandle) bool` | Is voice still playing? |

---

## Animation

| Function | Signature | Description |
|----------|-----------|-------------|
| `animPlay` | `(entity_id: u64, clip_asset_id: []const u8, blend_duration: f32) void` | Play animation clip with blend transition |
| `animStop` | `(entity_id: u64) void` | Stop animation |
| `animSetSpeed` | `(entity_id: u64, speed: f32) void` | Set playback speed |
| `animIsPlaying` | `(entity_id: u64) bool` | Is entity playing an animation? |

---

## Canvas / UI

Immediate-mode UI widgets rendered as screen-space overlay.

| Function | Signature | Description |
|----------|-----------|-------------|
| `canvasClear` | `() void` | Remove all widgets |
| `canvasAddText` | `(x, y, w, h: f32, text: []const u8, r, g, b, a: u8) WidgetId` | Add text label |
| `canvasAddPanel` | `(x, y, w, h: f32, r, g, b, a: u8) WidgetId` | Add colored rectangle |
| `canvasAddButton` | `(x, y, w, h: f32, label: []const u8) WidgetId` | Add clickable button |
| `canvasAddProgressBar` | `(x, y, w, h: f32, value: f32) WidgetId` | Add progress bar (0..1) |
| `canvasSetText` | `(id: WidgetId, text: []const u8) void` | Update text content |
| `canvasSetProgress` | `(id: WidgetId, value: f32) void` | Update progress value |
| `canvasSetVisible` | `(id: WidgetId, visible: bool) void` | Show / hide widget |
| `canvasRemoveWidget` | `(id: WidgetId) void` | Delete widget |
| `canvasWasButtonClicked` | `(id: WidgetId) bool` | Was button clicked this frame? |

---

## Logging

| Function | Signature | Description |
|----------|-----------|-------------|
| `log` | `(msg: []const u8) void` | Print message to engine console |

---

## Minimal Example

```zig
const guava = @import("guava");
const std = @import("std");

var score_label: guava.WidgetId = 0;
var score: u32 = 0;

export fn guava_on_init() callconv(.c) void {
    guava.log("Game started!");
    score_label = guava.canvasAddText(10, 10, 200, 30, "Score: 0", 255, 255, 255, 255);
}

export fn guava_on_update(dt: f32) callconv(.c) void {
    var pos = guava.getPosition();

    // WASD movement
    if (guava.isKeyDown(.w)) pos[2] -= 5.0 * dt;
    if (guava.isKeyDown(.s)) pos[2] += 5.0 * dt;
    if (guava.isKeyDown(.a)) pos[0] -= 5.0 * dt;
    if (guava.isKeyDown(.d)) pos[0] += 5.0 * dt;

    guava.setPosition(pos);

    // Raycast downward
    if (guava.raycast(pos, .{ 0, -1, 0 }, 2.0)) |hit| {
        _ = hit;
    }
}
```
