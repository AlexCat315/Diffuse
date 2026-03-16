const std = @import("std");
const engine = @import("guava");
const editor_layer_mod = @import("editor/core/layer.zig");

const CliOptions = struct {
    frame_count: usize = 0,
    backend_order: [3]engine.render.GraphicsAPI = .{ .vulkan, .dx12, .metal },
    backend_count: usize = 3,

    fn backends(self: *const CliOptions) []const engine.render.GraphicsAPI {
        return self.backend_order[0..self.backend_count];
    }
};

const SandboxLayer = struct {
    spinning_entity: ?engine.scene.EntityId = null,

    pub fn asLayer(self: *SandboxLayer) engine.core.Layer {
        return .{
            .name = "Sandbox3D",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_update = onUpdate,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *engine.core.LayerContext) anyerror!void {
        const self: *SandboxLayer = @ptrCast(@alignCast(context));
        const cube_mesh = try layer_context.world.assets().ensurePrimitiveMesh(.cube);
        const default_material = try layer_context.world.assets().ensureDefaultMaterial();
        self.spinning_entity = try layer_context.world.createEntity(.{
            .name = "Spinner",
            .mesh = .{
                .handle = cube_mesh,
                .primitive = .cube,
            },
            .material = .{
                .handle = default_material,
            },
            .transform = .{
                .translation = .{ 2.0, 1.0, 0.0 },
                .scale = .{ 1.0, 1.5, 1.0 },
            },
        });

        _ = try layer_context.world.createEntity(.{
            .name = "SpinnerChild",
            .parent = self.spinning_entity,
            .mesh = .{
                .handle = cube_mesh,
                .primitive = .cube,
            },
            .material = .{
                .handle = default_material,
            },
            .transform = .{
                .translation = .{ 1.1, 0.9, 0.0 },
                .scale = .{ 0.35, 0.35, 0.35 },
            },
        });

        _ = try layer_context.world.importGltfStaticModel(
            "assets/models/guava_showcase/guava_showcase.gltf",
            .{
                .translation = .{ -2.4, 0.0, 0.0 },
            },
        );
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) anyerror!void {
        const self: *SandboxLayer = @ptrCast(@alignCast(context));
        if (self.spinning_entity) |entity_id| {
            if (layer_context.world.getEntity(entity_id)) |entity| {
                entity.transform.rotation_euler[1] += 0.75 * layer_context.delta_seconds;
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const options = try parseCliOptions(allocator);

    var app = try engine.core.Application.init(allocator, .{
        .name = "Guava Engine",
        .window_width = 1440,
        .window_height = 900,
        .window_borderless = true,
        .window_native_titlebar_controls = true,
        .frame_delay_ms = 16,
        .preferred_backends = options.backends(),
    });
    defer app.deinit();

    var sandbox_layer = SandboxLayer{};
    try app.pushLayer(sandbox_layer.asLayer());
    var editor_layer = editor_layer_mod.EditorLayer{};
    try app.pushOverlay(editor_layer.asLayer());

    const report = try app.run(options.frame_count);
    const device_name = if (report.runtime.deviceName().len == 0) "Unknown Device" else report.runtime.deviceName();
    const driver_name = if (report.runtime.driverName().len == 0) "Unknown Driver" else report.runtime.driverName();
    const driver_info = if (report.runtime.driverInfo().len == 0) "n/a" else report.runtime.driverInfo();
    const depth_state = if (report.runtime.has_depth) "ready" else "missing";

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        "Engine {s} booted on {s} with {s}. Device: {s}. Drawable: {d}x{d}. Depth: {s}. Frames: {d}, passes: {d}, draws: {d}, triangles: {d}, entities: {d}, meshes: {d}, lights: {d}\n",
        .{
            app.config.name,
            engine.core.platformName(app.platform),
            engine.render.graphicsApiName(report.backend),
            device_name,
            report.runtime.drawable_width,
            report.runtime.drawable_height,
            depth_state,
            report.frames,
            report.passes,
            report.draw_calls,
            report.triangles_drawn,
            report.scene.entity_count,
            report.scene.mesh_count,
            report.scene.light_count,
        },
    );
    try stdout.print("RHI driver: {s}\n", .{driver_name});
    try stdout.print("Driver info: {s}\n", .{driver_info});
    try stdout.flush();
}

test "main boots the engine skeleton" {
    try std.testing.expect(true);
}

fn parseCliOptions(allocator: std.mem.Allocator) !CliOptions {
    var options = CliOptions{};
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--backend")) {
            index += 1;
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            options.backend_order = backendOrderForName(args[index]) orelse return error.InvalidArguments;
            options.backend_count = options.backend_order.len;
            continue;
        }
        if (std.mem.eql(u8, arg, "--frames")) {
            index += 1;
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            options.frame_count = try std.fmt.parseUnsigned(usize, args[index], 10);
            continue;
        }
        return error.InvalidArguments;
    }

    return options;
}

fn backendOrderForName(name: []const u8) ?[3]engine.render.GraphicsAPI {
    if (std.mem.eql(u8, name, "vulkan")) {
        return .{ .vulkan, .metal, .dx12 };
    }
    if (std.mem.eql(u8, name, "metal")) {
        return .{ .metal, .vulkan, .dx12 };
    }
    if (std.mem.eql(u8, name, "dx12")) {
        return .{ .dx12, .vulkan, .metal };
    }
    return null;
}
