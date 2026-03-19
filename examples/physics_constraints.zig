const std = @import("std");
const guava = @import("guava");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try guava.Engine.init(allocator, .{});
    defer engine.deinit();

    var world = try guava.scene.World.init(allocator, null);
    defer world.deinit();

    // 创建地面
    _ = try world.createEntity(.{
        .name = "Ground",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{ .half_extents = .{ 10.0, 0.5, 10.0 } },
    });

    // 创建摆锤的固定点
    const anchor_id = try world.createEntity(.{
        .name = "Anchor",
        .local_transform = .{ .translation = .{ 0.0, 5.0, 0.0 } },
        .rigidbody = .{ .motion_type = .static },
    });

    // 创建摆锤物体
    const pendulum_id = try world.createEntity(.{
        .name = "Pendulum",
        .local_transform = .{ .translation = .{ 2.0, 5.0, 0.0 } },
        .rigidbody = .{ 
            .motion_type = .dynamic,
            .mass = 1.0,
        },
        .box_collider = .{ .half_extents = .{ 0.2, 0.2, 0.2 } },
    });

    // 创建 Point-to-Point 约束（摆锤）
    _ = try world.createEntity(.{
        .name = "PendulumConstraint",
        .constraint = .{
            .constraint_type = .point_to_point,
            .entity_a = anchor_id,
            .entity_b = pendulum_id,
            .pivot_a = .{ 0.0, 0.0, 0.0 },
            .pivot_b = .{ 0.0, 0.0, 0.0 },
        },
    });

    // 创建铰链门
    const door_frame_id = try world.createEntity(.{
        .name = "DoorFrame",
        .local_transform = .{ .translation = .{ -3.0, 2.0, 0.0 } },
        .rigidbody = .{ .motion_type = .static },
    });

    const door_id = try world.createEntity(.{
        .name = "Door",
        .local_transform = .{ .translation = .{ -2.0, 2.0, 0.0 } },
        .rigidbody = .{ 
            .motion_type = .dynamic,
            .mass = 5.0,
        },
        .box_collider = .{ .half_extents = .{ 0.1, 2.0, 1.0 } },
    });

    // 创建 Hinge 约束（门）
    _ = try world.createEntity(.{
        .name = "DoorHinge",
        .constraint = .{
            .constraint_type = .hinge,
            .entity_a = door_frame_id,
            .entity_b = door_id,
            .pivot_a = .{ 0.0, 0.0, 0.0 },
            .pivot_b = .{ -1.0, 0.0, 0.0 },
            .axis_a = .{ 0.0, 1.0, 0.0 },
            .axis_b = .{ 0.0, 1.0, 0.0 },
            .min_limit = -1.57, // -90 度
            .max_limit = 1.57,  // +90 度
        },
    });

    // 设置 trigger 回调用于测试
    guava.physics.setTriggerCallback(struct {
        fn onTrigger(event: guava.physics.TriggerEvent) void {
            std.log.info("Trigger event: {} - {} - {}", .{
                event.entity_a,
                event.entity_b,
                @tagName(event.kind),
            });
        }
    }.onTrigger);

    // 主循环
    var timer = try std.time.Timer.start();
    const target_fps = 60;
    const frame_time_ns = std.time.ns_per_s / target_fps;

    while (!engine.shouldClose()) {
        const start_ns = timer.lap();

        engine.pollEvents();

        // 物理更新
        _ = guava.physics.step(&world, 1.0 / @as(f32, @floatFromInt(target_fps)), .{});

        // 处理 trigger 事件
        const trigger_events = guava.physics.pollTriggerEvents();
        defer guava.physics.clearTriggerEvents();
        
        for (trigger_events) |event| {
            std.log.info("Processing trigger: {} - {} - {}", .{
                event.entity_a,
                event.entity_b,
                @tagName(event.kind),
            });
        }

        // 渲染
        try engine.render(&world);

        const end_ns = timer.read();
        const elapsed_ns = end_ns - start_ns;
        if (elapsed_ns < frame_time_ns) {
            std.time.sleep(frame_time_ns - elapsed_ns);
        }
    }
}
