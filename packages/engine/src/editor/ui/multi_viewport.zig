const std = @import("std");
const engine = @import("guava");
const gui = @import("gui.zig");

pub const ViewportLayout = enum {
    single,
    horizontal_split,
    vertical_split,
    four_way,
    custom,
};

pub const ViewportType = enum {
    perspective,
    top,
    front,
    right,
    bottom,
    back,
    left,
    custom,
};

pub const ViewportConfig = struct {
    viewport_type: ViewportType = .perspective,
    camera_entity_id: ?engine.scene.EntityId = null,
    name: [64]u8 = [_]u8{0} ** 64,
    visible: bool = true,
    render_mode: engine.render.RenderMode = .lit,
    show_grid: bool = true,
    show_bones: bool = false,
    show_collision: bool = false,

    pub fn init(viewport_type: ViewportType) ViewportConfig {
        var config = ViewportConfig{
            .viewport_type = viewport_type,
        };
        const name = switch (viewport_type) {
            .perspective => "Perspective",
            .top => "Top",
            .front => "Front",
            .right => "Right",
            .bottom => "Bottom",
            .back => "Back",
            .left => "Left",
            .custom => "Custom",
        };
        @memcpy(config.name[0..name.len], name);
        return config;
    }
};

pub const ViewportPanel = struct {
    config: ViewportConfig,
    origin: [2]f32 = .{ 0, 0 },
    extent: [2]f32 = .{ 0, 0 },
    hovered: bool = false,
    focused: bool = false,
    has_image: bool = false,

    pub fn init(config: ViewportConfig) ViewportPanel {
        return .{
            .config = config,
        };
    }
};

pub const MultiViewportState = struct {
    allocator: std.mem.Allocator,
    layout: ViewportLayout = .single,
    panels: std.ArrayList(ViewportPanel),
    active_panel_index: usize = 0,
    split_ratio: f32 = 0.5,
    show_layout_selector: bool = false,

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
        self.layout = layout;
        self.panels.clearRetainingCapacity();

        switch (layout) {
            .single => {
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.perspective))) catch {};
            },
            .horizontal_split => {
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.perspective))) catch {};
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.front))) catch {};
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
            .custom => {
                self.panels.append(ViewportPanel.init(ViewportConfig.init(.perspective))) catch {};
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
        for (self.panels.items, 0..) |*panel, index| {
            if (x >= panel.origin[0] and
                x <= panel.origin[0] + panel.extent[0] and
                y >= panel.origin[1] and
                y <= panel.origin[1] + panel.extent[1])
            {
                self.active_panel_index = index;
                return panel;
            }
        }
        return null;
    }

    pub fn calculatePanelRects(self: *const MultiViewportState, total_origin: [2]f32, total_extent: [2]f32) []const [4]f32 {
        _ = self;
        _ = total_origin;
        _ = total_extent;
        const rects = [_][4]f32{
            .{ 0, 0, 0, 0 },
        };
        return &rects;
    }
};

pub fn drawViewportLayoutSelector(state: *MultiViewportState) void {
    if (gui.beginCombo("Layout", layoutName(state.layout), .{})) {
        defer gui.endCombo();

        const layouts = [_]ViewportLayout{ .single, .horizontal_split, .vertical_split, .four_way };
        for (layouts) |layout| {
            const is_selected = state.layout == layout;
            if (gui.selectable(layoutName(layout), is_selected)) {
                state.setLayout(layout);
            }
            if (is_selected) {
                gui.setItemDefaultFocus();
            }
        }
    }
}

fn layoutName(layout: ViewportLayout) []const u8 {
    return switch (layout) {
        .single => "Single",
        .horizontal_split => "Horizontal Split",
        .vertical_split => "Vertical Split",
        .four_way => "4-Way",
        .custom => "Custom",
    };
}
