const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");

pub const ViewportLayout = enum {
    single,
    horizontal_split,
    vertical_split,
    four_way,
};

pub const ViewportType = enum {
    perspective,
    top,
    front,
    right,
};

pub const ViewportConfig = struct {
    viewport_type: ViewportType,
    camera_distance: f32 = 10.0,
    fov: f32 = 60.0,
    orthographic: bool = false,

    pub fn init(viewport_type: ViewportType) ViewportConfig {
        return .{
            .viewport_type = viewport_type,
            .camera_distance = switch (viewport_type) {
                .perspective => 10.0,
                .top => 20.0,
                .front => 20.0,
                .right => 20.0,
            },
            .fov = 60.0,
            .orthographic = viewport_type != .perspective,
        };
    }
};

pub const ViewportPanel = struct {
    config: ViewportConfig,
    origin: [2]f32 = .{ 0, 0 },
    extent: [2]f32 = .{ 0, 0 },
    hovered: bool = false,
    focused: bool = false,
    camera_pitch: f32 = 0.0,
    camera_yaw: f32 = 0.0,

    pub fn init(config: ViewportConfig) ViewportPanel {
        return .{
            .config = config,
            .camera_pitch = switch (config.viewport_type) {
                .perspective => -30.0,
                .top => -90.0,
                .front => 0.0,
                .right => 90.0,
            },
            .camera_yaw = switch (config.viewport_type) {
                .perspective => 0.0,
                .top => 0.0,
                .front => 0.0,
                .right => 0.0,
            },
        };
    }

    pub fn getCameraDirection(self: *const ViewportPanel) [3]f32 {
        const pitch_rad = self.camera_pitch * std.math.pi / 180.0;
        const yaw_rad = self.camera_yaw * std.math.pi / 180.0;

        return .{
            @cos(pitch_rad) * @cos(yaw_rad),
            @sin(pitch_rad),
            @cos(pitch_rad) * @sin(yaw_rad),
        };
    }

    pub fn getCameraPosition(self: *const ViewportPanel, target: [3]f32) [3]f32 {
        const dir = self.getCameraDirection();
        return .{
            target[0] - dir[0] * self.config.camera_distance,
            target[1] - dir[1] * self.config.camera_distance,
            target[2] - dir[2] * self.config.camera_distance,
        };
    }
};

pub const MultiViewportState = struct {
    allocator: std.mem.Allocator,
    layout: ViewportLayout = .single,
    panels: std.ArrayList(ViewportPanel),
    active_panel_index: usize = 0,
    split_ratio: f32 = 0.5,
    target_position: [3]f32 = .{ 0, 0, 0 },

    pub fn init(allocator: std.mem.Allocator) MultiViewportState {
        var state = MultiViewportState{
            .allocator = allocator,
            .panels = std.ArrayList(ViewportPanel).init(allocator),
        };
        state.panels.append(ViewportPanel.init(ViewportConfig.init(.perspective))) catch {};
        return state;
    }

    pub fn deinit(self: *MultiViewportState) void {
        self.panels.deinit();
        self.* = undefined;
    }

    pub fn setLayout(self: *MultiViewportState, layout: ViewportLayout) void {
        if (self.layout == layout) return;
        self.layout = layout;
        self.panels.clearRetainingCapacity();

        switch (layout) {
            .single => {
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.perspective))) catch {};
            },
            .horizontal_split => {
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.perspective))) catch {};
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.top))) catch {};
            },
            .vertical_split => {
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.perspective))) catch {};
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.right))) catch {};
            },
            .four_way => {
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.perspective))) catch {};
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.top))) catch {};
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.front))) catch {};
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.right))) catch {};
            },
        }

        self.active_panel_index = 0;
    }

    pub fn activePanel(self: *MultiViewportState) ?*ViewportPanel {
        if (self.active_panel_index < self.panels.items.len) {
            return &self.panels.items[self.active_panel_index];
        }
        return null;
    }

    pub fn panelAt(self: *MultiViewportState, x: f32, y: f32) ?*ViewportPanel {
        for (self.panels.items) |*panel| {
            if (x >= panel.origin[0] and x < panel.origin[0] + panel.extent[0] and
                y >= panel.origin[1] and y < panel.origin[1] + panel.extent[1])
            {
                return panel;
            }
        }
        return null;
    }

    pub fn layoutName(layout: ViewportLayout) []const u8 {
        return switch (layout) {
            .single => "Single",
            .horizontal_split => "Horizontal Split",
            .vertical_split => "Vertical Split",
            .four_way => "4-Way",
        };
    }
};

pub fn drawMultiViewportSelector(state: *MultiViewportState) void {
    if (gui.beginCombo("##viewport_layout", MultiViewportState.layoutName(state.layout), .{})) {
        defer gui.endCombo();

        const layouts = [_]ViewportLayout{ .single, .horizontal_split, .vertical_split, .four_way };
        for (layouts) |layout| {
            const is_selected = state.layout == layout;
            if (gui.selectable(MultiViewportState.layoutName(layout), is_selected)) {
                state.setLayout(layout);
            }
            if (is_selected) {
                gui.setItemDefaultFocus();
            }
        }
    }
}

pub fn drawMultiViewportToolbar(state: *MultiViewportState) void {
    drawMultiViewportSelector(state);
    gui.sameLine();
    gui.text("Split:");
    gui.sameLine();
    if (gui.button("1")) {
        state.setLayout(.single);
    }
    gui.sameLine();
    if (gui.button("2H")) {
        state.setLayout(.horizontal_split);
    }
    gui.sameLine();
    if (gui.button("2V")) {
        state.setLayout(.vertical_split);
    }
    gui.sameLine();
    if (gui.button("4")) {
        state.setLayout(.four_way);
    }
}
