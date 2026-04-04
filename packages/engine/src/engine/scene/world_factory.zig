//! 实体工厂方法
//!
//! 提供快捷方法创建常用实体类型（原始体、空实体、相机、光源、VFX）
//! 以及场景引导（bootstrap3D）。

const std = @import("std");
const components = @import("components.zig");

/// 创建原始体实体（立方体、球体、平面等）
pub fn createPrimitiveEntity(
    self: anytype,
    primitive: components.Primitive,
    transform: components.Transform,
) !u64 {
    const mesh_handle = try self.resources.ensurePrimitiveMesh(primitive);
    const material_handle = try self.resources.ensureDefaultMaterial();
    const base_name = switch (primitive) {
        .cube => "Cube",
        .sphere => "Sphere",
        .plane => "Plane",
        .custom => "Mesh",
    };
    const entity_name = try self.nextAvailableName(base_name);
    defer self.allocator.free(entity_name);

    return self.createEntity(.{
        .name = entity_name,
        .local_transform = transform,
        .mesh = .{
            .handle = mesh_handle,
            .primitive = primitive,
        },
        .material = .{
            .handle = material_handle,
        },
    });
}

/// 创建空实体
pub fn createEmptyEntity(self: anytype, transform: components.Transform) !u64 {
    const entity_name = try self.nextAvailableName("Empty");
    defer self.allocator.free(entity_name);

    return self.createEntity(.{
        .name = entity_name,
        .local_transform = transform,
    });
}

/// 创建文件夹实体（用于层级面板分组）
pub fn createFolderEntity(self: anytype, transform: components.Transform) !u64 {
    const entity_name = try self.nextAvailableName("Folder");
    defer self.allocator.free(entity_name);

    return self.createEntity(.{
        .name = entity_name,
        .local_transform = transform,
        .is_folder = true,
    });
}

/// 创建相机实体
pub fn createCameraEntity(self: anytype, transform: components.Transform) !u64 {
    const entity_name = try self.nextAvailableName("Camera");
    defer self.allocator.free(entity_name);

    return self.createEntity(.{
        .name = entity_name,
        .local_transform = transform,
        .camera = .{},
    });
}

/// 创建光源实体（方向光、点光源、聚光灯）
pub fn createLightEntity(
    self: anytype,
    kind: components.LightKind,
    transform: components.Transform,
    intensity: f32,
) !u64 {
    const base_name = switch (kind) {
        .directional => "DirectionalLight",
        .point => "PointLight",
        .spot => "SpotLight",
    };
    const entity_name = try self.nextAvailableName(base_name);
    defer self.allocator.free(entity_name);

    var light_transform = transform;
    var mesh: ?components.Mesh = null;
    var material: ?components.Material = null;

    if (kind != .directional) {
        const proxy_mesh = try self.resources.ensurePrimitiveMesh(.sphere);
        const material_name = try std.fmt.allocPrint(self.allocator, "{s}Material", .{entity_name});
        defer self.allocator.free(material_name);
        const tint: [4]f32 = switch (kind) {
            .point => .{ 1.0, 0.86, 0.55, 1.0 },
            .spot => .{ 0.65, 0.8, 1.0, 1.0 },
            .directional => .{ 1.0, 1.0, 1.0, 1.0 },
        };
        const proxy_material = try self.resources.createMaterial(.{
            .name = material_name,
            .base_color_factor = tint,
            .base_color_texture = try self.resources.ensureWhiteTexture(),
        });

        light_transform.scale = switch (kind) {
            .point => .{ 0.18, 0.18, 0.18 },
            .spot => .{ 0.24, 0.24, 0.24 },
            .directional => light_transform.scale,
        };
        mesh = .{
            .handle = proxy_mesh,
            .primitive = .sphere,
        };
        material = .{
            .handle = proxy_material,
            .base_color_factor = tint,
        };
    }

    return self.createEntity(.{
        .name = entity_name,
        .local_transform = light_transform,
        .mesh = mesh,
        .material = material,
        .light = .{
            .kind = kind,
            .intensity = intensity,
            .range = if (kind == .point) 12.0 else 10.0,
        },
    });
}

/// 创建 VFX（粒子特效）实体
pub fn createVfxEntity(
    self: anytype,
    kind: components.VfxKind,
    transform: components.Transform,
) !u64 {
    const base_name = switch (kind) {
        .fountain => "FountainVfx",
        .orbit => "OrbitVfx",
    };
    const entity_name = try self.nextAvailableName(base_name);
    defer self.allocator.free(entity_name);

    const mesh_handle = try self.resources.ensurePrimitiveMesh(.sphere);
    const vfx = components.defaultVfx(kind);
    var root_transform = transform;
    root_transform.scale = switch (kind) {
        .fountain => .{ 0.18, 0.18, 0.18 },
        .orbit => .{ 0.2, 0.2, 0.2 },
    };

    return self.createEntity(.{
        .name = entity_name,
        .local_transform = root_transform,
        .mesh = .{
            .handle = mesh_handle,
            .primitive = .sphere,
        },
        .material = .{
            .shading = .unlit,
            .base_color_factor = .{ vfx.color[0], vfx.color[1], vfx.color[2], 1.0 },
        },
        .vfx = vfx,
    });
}

/// 引导场景：创建相机、太阳光、地面和主角方块
pub fn bootstrap3D(self: anytype) !void {
    const quat = @import("../math/quat.zig");
    const plane_mesh = try self.resources.ensurePrimitiveMesh(.plane);
    const cube_mesh = try self.resources.ensurePrimitiveMesh(.cube);
    const hero_albedo = try self.resources.createTexture(.{
        .name = "BootstrapHeroAlbedo",
        .width = 2,
        .height = 2,
        .pixels = &[_]u8{
            214, 214, 220, 255,
            182, 186, 194, 255,
            182, 186, 194, 255,
            214, 214, 220, 255,
        },
    });
    const ground_material = try self.resources.createMaterial(.{
        .name = "BootstrapGroundMaterial",
        .base_color_factor = .{ 0.56, 0.57, 0.59, 1.0 },
        .metallic_factor = 0.0,
        .roughness_factor = 0.97,
        .use_ibl = false,
        .ibl_intensity = 0.0,
    });
    const hero_material = try self.resources.createMaterial(.{
        .name = "BootstrapHeroMaterial",
        .base_color_factor = .{ 1.0, 1.0, 1.0, 1.0 },
        .base_color_texture = hero_albedo,
        .metallic_factor = 0.0,
        .roughness_factor = 0.62,
        .use_ibl = true,
        .ibl_intensity = 0.2,
    });

    _ = try self.createEntity(.{
        .name = "MainCamera",
        .camera = .{ .is_primary = true },
        .local_transform = .{
            .translation = .{ 0.0, 1.5, 5.0 },
        },
    });

    _ = try self.createEntity(.{
        .name = "Sun",
        .light = .{
            .kind = .directional,
            .color = .{ 1.0, 0.985, 0.95 },
            .intensity = 3.25,
        },
        .local_transform = .{
            .rotation = quat.fromEuler(.{ -0.9, 0.6, 0.0 }),
        },
    });

    _ = try self.createEntity(.{
        .name = "Ground",
        .mesh = .{
            .handle = plane_mesh,
            .primitive = .plane,
        },
        .rigidbody = .{
            .motion_type = .static,
        },
        .box_collider = .{
            .half_extents = .{ 500.0, 0.1, 500.0 },
        },
        .material = .{
            .handle = ground_material,
        },
        .local_transform = .{
            .scale = .{ 1000.0, 1.0, 1000.0 },
        },
    });

    _ = try self.createEntity(.{
        .name = "Hero",
        .mesh = .{
            .handle = cube_mesh,
            .primitive = .cube,
        },
        .rigidbody = .{
            .motion_type = .dynamic,
        },
        .box_collider = .{
            .half_extents = .{ 0.5, 0.5, 0.5 },
        },
        .material = .{
            .handle = hero_material,
        },
        .local_transform = .{
            .translation = .{ 0.0, 1.0, 0.0 },
        },
    });
}
