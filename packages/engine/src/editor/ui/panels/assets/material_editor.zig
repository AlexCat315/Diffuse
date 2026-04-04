const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const state_mod = @import("../../../core/state.zig");
const utils = @import("../../../common/utils.zig");
const history = @import("../../../actions/history.zig");
const content_browser = @import("../../../assets/browser.zig");
const inspector = @import("../scene/inspector.zig");
const ui_icons = @import("../../icons.zig");
const layout = @import("../../layout.zig");

const preview_texture_size_min: f32 = 168.0;
const preview_texture_size_max: f32 = 320.0;
const slot_thumbnail_size: f32 = 64.0;

const MaterialTextureSlot = enum {
    base_color,
    metallic_roughness,
    normal,
    occlusion,
    emissive,
};

pub fn drawMaterialEditorWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .material_editor, "material_editor_popup");
    var open = state.material_editor_open;
    _ = gui.beginWindowFlagsOpen(title, &open, gui.WindowFlags.no_docking);
    state.material_editor_open = open;
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("material_editor_popup");

    if (!open) return;

    layout.beginSectionBody();
    defer layout.endSectionBody();

    const selected = layer_context.renderer.selectedEntity() orelse {
        gui.text(state.text(.no_entity_selected));
        return;
    };

    const entity = layer_context.world.getEntity(selected) orelse {
        gui.text(state.text(.selection_is_stale));
        return;
    };

    if (entity.material == null) {
        gui.text(state.text(.entity_has_no_material));
        if (gui.buttonEx(state.text(.add_material_component), gui.contentRegionAvail()[0], 0.0)) {
            try inspector.addMaterialComponent(state, layer_context, entity);
        }
        return;
    }

    const material_component = &entity.material.?;

    gui.text(state.text(.material));
    gui.sameLine();
    var material_name: []const u8 = state.text(.embedded);
    if (material_component.handle) |material_handle| {
        if (layer_context.world.assets().material(material_handle)) |material_resource| {
            material_name = material_resource.name;
        }
    }
    gui.text(material_name);

    var usage_count: usize = 0;
    var is_shared = false;
    var current_material_resource: ?*const engine.assets.MaterialResource = null;
    if (material_component.handle) |material_handle| {
        usage_count = inspector.materialUsageCount(state, layer_context.world, material_handle);
        is_shared = usage_count > 1;
        current_material_resource = layer_context.world.assets().material(material_handle);
    }

    if (material_component.handle != null) {
        var usage_buffer: [96]u8 = undefined;
        const usage_text = std.fmt.bufPrint(&usage_buffer, "Material Usage: {d}", .{usage_count}) catch "Material Usage: ?";
        gui.text(usage_text);
    } else {
        gui.text("Material Usage: Embedded (entity local)");
    }

    if (is_shared) {
        gui.text("Shared material detected. Editing will create a unique instance for this entity.");
        if (gui.buttonEx("Make Unique Instance", -1.0, 0.0)) {
            _ = try inspector.ensureEditableMaterialResource(state, layer_context, entity);
            try history.captureSnapshot(state, layer_context);
        }
    }

    drawMaterialInheritanceSummary(layer_context, current_material_resource, usage_count, is_shared);

    gui.separator();

    var shading = material_component.shading;
    gui.text(state.text(.shading));
    gui.sameLine();
    if (gui.beginMenu(utils.shadingLabel(state, shading))) {
        defer gui.endMenu();
        if (gui.menuItem(state.text(.unlit), null, shading == .unlit, true)) shading = .unlit;
        if (gui.menuItem(state.text(.lambert), null, shading == .lambert, true)) shading = .lambert;
        if (gui.menuItem(state.text(.pbr), null, shading == .pbr_metallic_roughness, true)) shading = .pbr_metallic_roughness;
    }
    if (shading != material_component.shading) {
        if (materialAstFromEntity(layer_context, entity)) |source_ast| {
            var ast = source_ast;
            ast.shading = shading;
            if (try commitAstToEditableMaterial(state, layer_context, entity, &ast)) {
                try history.captureSnapshot(state, layer_context);
            }
        }
    }

    gui.dummy(0.0, 8.0);

    var base_color = material_component.base_color_factor;
    var base_rgb: [3]f32 = .{ base_color[0], base_color[1], base_color[2] };
    gui.text(state.text(.base_color));
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat3("##material_base_color", &base_rgb, 0.01, 0.0, 1.0)) {
        base_color[0] = std.math.clamp(base_rgb[0], 0.0, 1.0);
        base_color[1] = std.math.clamp(base_rgb[1], 0.0, 1.0);
        base_color[2] = std.math.clamp(base_rgb[2], 0.0, 1.0);
        if (materialAstFromEntity(layer_context, entity)) |source_ast| {
            var ast = source_ast;
            ast.base_color_factor = base_color;
            _ = try commitAstToEditableMaterial(state, layer_context, entity, &ast);
        }
    }
    if (gui.isItemDeactivatedAfterEdit()) try history.captureSnapshot(state, layer_context);

    gui.dummy(0.0, 8.0);

    var opacity = base_color[3];
    gui.text(state.text(.opacity));
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat("##material_opacity", &opacity, 0.01, 0.0, 1.0)) {
        base_color[3] = std.math.clamp(opacity, 0.0, 1.0);
        if (materialAstFromEntity(layer_context, entity)) |source_ast| {
            var ast = source_ast;
            ast.base_color_factor = base_color;
            _ = try commitAstToEditableMaterial(state, layer_context, entity, &ast);
        }
    }
    if (gui.isItemDeactivatedAfterEdit()) try history.captureSnapshot(state, layer_context);

    gui.dummy(0.0, 8.0);

    var metallic = material_component.metallic_factor;
    gui.text("Metallic");
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat("##material_metallic", &metallic, 0.01, 0.0, 1.0)) {
        const clamped = std.math.clamp(metallic, 0.0, 1.0);
        if (materialAstFromEntity(layer_context, entity)) |source_ast| {
            var ast = source_ast;
            ast.metallic_factor = clamped;
            _ = try commitAstToEditableMaterial(state, layer_context, entity, &ast);
        }
    }
    if (gui.isItemDeactivatedAfterEdit()) try history.captureSnapshot(state, layer_context);

    gui.dummy(0.0, 8.0);

    var roughness = material_component.roughness_factor;
    gui.text("Roughness");
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat("##material_roughness", &roughness, 0.01, 0.0, 1.0)) {
        const clamped = std.math.clamp(roughness, 0.0, 1.0);
        if (materialAstFromEntity(layer_context, entity)) |source_ast| {
            var ast = source_ast;
            ast.roughness_factor = clamped;
            _ = try commitAstToEditableMaterial(state, layer_context, entity, &ast);
        }
    }
    if (gui.isItemDeactivatedAfterEdit()) try history.captureSnapshot(state, layer_context);

    gui.dummy(0.0, 8.0);

    var emissive = material_component.emissive_factor;
    gui.text("Emissive");
    gui.setNextItemWidth(-1.0);
    if (gui.colorEdit3("##material_emissive", &emissive, .{})) {
        if (materialAstFromEntity(layer_context, entity)) |source_ast| {
            var ast = source_ast;
            ast.emissive_factor = emissive;
            if (try commitAstToEditableMaterial(state, layer_context, entity, &ast)) {
                try history.captureSnapshot(state, layer_context);
            }
        }
    }

    gui.dummy(0.0, 8.0);

    var alpha_cutoff = material_component.alpha_cutoff;
    gui.text("Alpha Cutoff");
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat("##material_alpha_cutoff", &alpha_cutoff, 0.01, 0.0, 1.0)) {
        const clamped = std.math.clamp(alpha_cutoff, 0.0, 1.0);
        if (materialAstFromEntity(layer_context, entity)) |source_ast| {
            var ast = source_ast;
            ast.alpha_cutoff = clamped;
            _ = try commitAstToEditableMaterial(state, layer_context, entity, &ast);
        }
    }
    if (gui.isItemDeactivatedAfterEdit()) try history.captureSnapshot(state, layer_context);

    gui.dummy(0.0, 8.0);

    var double_sided = material_component.double_sided;
    if (gui.checkbox("Double Sided", &double_sided)) {
        if (materialAstFromEntity(layer_context, entity)) |source_ast| {
            var ast = source_ast;
            ast.double_sided = double_sided;
            if (try commitAstToEditableMaterial(state, layer_context, entity, &ast)) {
                try history.captureSnapshot(state, layer_context);
            }
        }
    }

    gui.separator();
    gui.text("Preview");

    const preview_width = std.math.clamp(gui.contentRegionAvail()[0], preview_texture_size_min, preview_texture_size_max);
    if (layer_context.renderer.materialEditorPreviewTexture()) |preview_texture| {
        gui.image(preview_texture, preview_width, preview_width);
    } else {
        gui.textWrapped("Preview is rendering in an isolated material scene.");
        gui.dummy(preview_width, preview_width * 0.28);
    }
    gui.dummy(0.0, 6.0);

    if (gui.buttonEx("Use Sphere Preview Mesh", -1.0, 0.0)) {
        state.material_editor_preview_primitive = .sphere;
    }
    if (gui.buttonEx("Use Plane Preview Mesh", -1.0, 0.0)) {
        state.material_editor_preview_primitive = .plane;
    }
    if (gui.buttonEx("Apply Checker To Base Color", -1.0, 0.0)) {
        const checker = try ensureMaterialPreviewCheckerTexture(layer_context);
        if (materialAstFromEntity(layer_context, entity)) |source_ast| {
            var ast = source_ast;
            ast.textures.base_color = checker;
            if (try commitAstToEditableMaterial(state, layer_context, entity, &ast)) {
                try history.captureSnapshot(state, layer_context);
            }
        }
    }

    gui.separator();
    gui.text("Texture Slots");

    if (try drawTextureSlot(state, layer_context, entity, .base_color)) try history.captureSnapshot(state, layer_context);
    if (try drawTextureSlot(state, layer_context, entity, .metallic_roughness)) try history.captureSnapshot(state, layer_context);
    if (try drawTextureSlot(state, layer_context, entity, .normal)) try history.captureSnapshot(state, layer_context);
    if (try drawTextureSlot(state, layer_context, entity, .occlusion)) try history.captureSnapshot(state, layer_context);
    if (try drawTextureSlot(state, layer_context, entity, .emissive)) try history.captureSnapshot(state, layer_context);

    if (materialAstFromEntity(layer_context, entity)) |current_ast| {
        try layer_context.renderer.requestMaterialEditorPreview(
            layer_context.world.assets(),
            &current_ast,
            state.material_editor_preview_primitive,
        );
    }
}

fn drawTextureSlot(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    slot: MaterialTextureSlot,
) !bool {
    gui.pushIdU64(@intFromEnum(slot));
    defer gui.popId();

    gui.separatorText(textureSlotLabel(slot));

    const material_handle = entity.material.?.handle;
    const material_resource = if (material_handle) |handle| layer_context.world.assets().material(handle) else null;
    const texture_handle = if (material_resource) |material| textureHandleForSlot(material, slot) else null;
    var has_texture = false;
    var texture_slot_text: []const u8 = state.text(.none);
    var missing_resource = false;
    if (texture_handle) |handle| {
        if (layer_context.world.assets().texture(handle)) |texture_resource| {
            texture_slot_text = texture_resource.name;
            has_texture = true;
        } else {
            texture_slot_text = "Missing imported texture";
            missing_resource = true;
        }
    }

    if (has_texture) {
        if (layer_context.renderer.texturePreviewTexture(layer_context.world, texture_handle.?)) |preview_texture| {
            gui.image(preview_texture, slot_thumbnail_size, slot_thumbnail_size);
        } else {
            gui.dummy(slot_thumbnail_size, slot_thumbnail_size);
        }
    } else {
        gui.dummy(slot_thumbnail_size, slot_thumbnail_size);
    }
    gui.sameLine();
    gui.textWrapped(textureSlotDescription(slot));

    if (missing_resource) {
        gui.textWrapped("This slot still points to a texture handle that is no longer loaded. Reassign it or clear the slot.");
    } else if (has_texture) {
        gui.textWrapped(texture_slot_text);
    } else {
        gui.textWrapped(textureSlotFallbackHint(slot));
    }

    const assign_label = if (has_texture) "Replace With Selected Texture" else "Assign Selected Texture";

    var changed = false;
    if (gui.buttonEx(assign_label, -1.0, 0.0)) {
        if (content_browser.selectedAssetCanUseAsTexture(state)) {
            changed = (try assignSelectedTextureToMaterialSlot(state, layer_context, entity, slot)) or changed;
        }
    }

    var dropped_texture: u64 = 0;
    if (gui.acceptDragDropPayloadU64(state_mod.asset_texture_drag_payload, &dropped_texture)) {
        const asset_index: usize = @intCast(dropped_texture);
        if (asset_index < state.asset_entries.items.len) {
            changed = (try assignTextureEntryToMaterialSlot(state, layer_context, entity, &state.asset_entries.items[asset_index], slot)) or changed;
        }
    }

    if (has_texture) {
        gui.sameLine();
        if (gui.buttonEx(state.text(.clear_texture), 0.0, 0.0)) {
            if (materialAstFromEntity(layer_context, entity)) |source_ast| {
                var ast = source_ast;
                setTextureHandleForAstSlot(&ast, slot, null);
                changed = (try commitAstToEditableMaterial(state, layer_context, entity, &ast)) or changed;
            }
        }
    }

    gui.textWrapped("Tip: click to use the current Content Browser texture, or drag a texture asset onto this slot.");
    gui.dummy(0.0, 6.0);
    return changed;
}

fn assignSelectedTextureToMaterialSlot(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    slot: MaterialTextureSlot,
) !bool {
    const entry = content_browser.selectedAsset(state) orelse return false;
    return assignTextureEntryToMaterialSlot(state, layer_context, entity, entry, slot);
}

fn assignTextureEntryToMaterialSlot(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    entry: *const state_mod.AssetEntry,
    slot: MaterialTextureSlot,
) !bool {
    if (entry.kind != .texture) return false;

    const texture_handle = try inspector.importTextureAsset(state, layer_context, entry.id, entry.path);
    if (materialAstFromEntity(layer_context, entity)) |source_ast| {
        var ast = source_ast;
        setTextureHandleForAstSlot(&ast, slot, texture_handle);
        return try commitAstToEditableMaterial(state, layer_context, entity, &ast);
    }
    return false;
}

fn textureHandleForSlot(material: *const engine.assets.MaterialResource, slot: MaterialTextureSlot) ?engine.assets.TextureHandle {
    return switch (slot) {
        .base_color => material.base_color_texture,
        .metallic_roughness => material.metallic_roughness_texture,
        .normal => material.normal_texture,
        .occlusion => material.occlusion_texture,
        .emissive => material.emissive_texture,
    };
}

fn setTextureHandleForAstSlot(ast: *engine.assets.MaterialAst, slot: MaterialTextureSlot, texture: ?engine.assets.TextureHandle) void {
    switch (slot) {
        .base_color => ast.textures.base_color = texture,
        .metallic_roughness => ast.textures.metallic_roughness = texture,
        .normal => ast.textures.normal = texture,
        .occlusion => ast.textures.occlusion = texture,
        .emissive => ast.textures.emissive = texture,
    }
}

fn textureSlotLabel(slot: MaterialTextureSlot) []const u8 {
    return switch (slot) {
        .base_color => "Base Color",
        .metallic_roughness => "Metallic/Roughness",
        .normal => "Normal",
        .occlusion => "Occlusion",
        .emissive => "Emissive",
    };
}

fn materialAstFromEntity(layer_context: *engine.core.LayerContext, entity: *const engine.scene.Entity) ?engine.assets.MaterialAst {
    const material_component = entity.material orelse return null;
    if (material_component.handle) |material_handle| {
        if (layer_context.world.assets().material(material_handle)) |material_resource| {
            return engine.assets.MaterialAst.fromResource(material_resource);
        }
    }

    return .{
        .name = "Embedded Material",
        .shading = material_component.shading,
        .base_color_factor = material_component.base_color_factor,
        .emissive_factor = material_component.emissive_factor,
        .metallic_factor = material_component.metallic_factor,
        .roughness_factor = material_component.roughness_factor,
        .alpha_cutoff = material_component.alpha_cutoff,
        .double_sided = material_component.double_sided,
        .inheritance = .{},
        .textures = .{},
    };
}

fn commitAstToEditableMaterial(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    ast: *const engine.assets.MaterialAst,
) !bool {
    if (entity.material == null) return false;
    if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
        const allocator = state.allocator orelse layer_context.world.allocator;
        material_resource.shading = ast.shading;
        material_resource.base_color_factor = ast.base_color_factor;
        material_resource.base_color_texture = ast.textures.base_color;
        material_resource.metallic_roughness_texture = ast.textures.metallic_roughness;
        material_resource.normal_texture = ast.textures.normal;
        material_resource.occlusion_texture = ast.textures.occlusion;
        material_resource.emissive_texture = ast.textures.emissive;
        material_resource.emissive_factor = ast.emissive_factor;
        material_resource.metallic_factor = ast.metallic_factor;
        material_resource.roughness_factor = ast.roughness_factor;
        material_resource.alpha_cutoff = ast.alpha_cutoff;
        material_resource.double_sided = ast.double_sided;
        material_resource.use_ibl = ast.use_ibl;
        material_resource.ibl_intensity = ast.ibl_intensity;
        try syncMaterialMetadataFromAst(allocator, material_resource, ast);

        const material_component = &entity.material.?;
        material_component.shading = ast.shading;
        material_component.base_color_factor = ast.base_color_factor;
        material_component.emissive_factor = ast.emissive_factor;
        material_component.metallic_factor = ast.metallic_factor;
        material_component.roughness_factor = ast.roughness_factor;
        material_component.alpha_cutoff = ast.alpha_cutoff;
        material_component.double_sided = ast.double_sided;
        material_component.handle = inspector.materialHandleForEntity(state, entity);
        return true;
    }
    return false;
}

fn syncMaterialMetadataFromAst(
    allocator: std.mem.Allocator,
    material_resource: *engine.assets.MaterialResource,
    ast: *const engine.assets.MaterialAst,
) !void {
    const parent_name_hint = if (ast.inheritance.parent_material_name_hint) |name| try allocator.dupe(u8, name) else null;
    errdefer if (parent_name_hint) |name| allocator.free(name);

    var graph_copy = if (ast.graph) |graph|
        try engine.assets.cloneMaterialGraphAlloc(allocator, graph)
    else
        try ast.canonicalGraphAlloc(allocator);
    errdefer engine.assets.deinitMaterialGraph(allocator, &graph_copy);

    if (material_resource.inheritance.parent_material_name_hint) |name| {
        allocator.free(@constCast(name));
    }
    if (material_resource.graph) |*graph| {
        engine.assets.deinitMaterialGraph(allocator, graph);
    }

    material_resource.inheritance = .{
        .parent_material_handle = ast.inheritance.parent_material_handle,
        .parent_material_name_hint = parent_name_hint,
        .generation = ast.inheritance.generation,
    };
    material_resource.graph = graph_copy;
}

fn drawMaterialInheritanceSummary(
    layer_context: *engine.core.LayerContext,
    material_resource: ?*const engine.assets.MaterialResource,
    usage_count: usize,
    is_shared: bool,
) void {
    const material = material_resource orelse return;

    gui.separatorText("Inheritance");
    if (material.inheritance.generation > 0) {
        var depth_buffer: [64]u8 = undefined;
        const depth_text = std.fmt.bufPrint(&depth_buffer, "Instance Depth: {d}", .{material.inheritance.generation}) catch "Instance Depth: ?";
        gui.text(depth_text);
    } else if (is_shared) {
        gui.textWrapped("This entity is still using a shared source material. Creating a unique instance will preserve a visible parent chain.");
    } else {
        gui.textWrapped("This material is currently the root editable resource for the selected entity.");
    }

    if (material.inheritance.parent_material_handle) |parent_handle| {
        const parent_name = if (layer_context.world.assets().material(parent_handle)) |parent|
            parent.name
        else if (material.inheritance.parent_material_name_hint) |hint|
            hint
        else
            "Unknown Parent";

        var parent_buffer: [192]u8 = undefined;
        const parent_text = std.fmt.bufPrint(&parent_buffer, "Parent Material: {s}", .{parent_name}) catch "Parent Material: ?";
        gui.textWrapped(parent_text);
    } else if (is_shared) {
        var usage_buffer: [96]u8 = undefined;
        const usage_text = std.fmt.bufPrint(&usage_buffer, "Shared by {d} entities before instancing.", .{usage_count}) catch "Shared by multiple entities before instancing.";
        gui.textWrapped(usage_text);
    }

    if (material.graph) |graph| {
        var graph_buffer: [128]u8 = undefined;
        const graph_text = std.fmt.bufPrint(&graph_buffer, "Phase-2 graph seed: {d} nodes, {d} outputs.", .{ graph.nodes.len, graph.outputs.len }) catch "Phase-2 graph seed ready.";
        gui.textWrapped(graph_text);
    }
}

fn textureSlotDescription(slot: MaterialTextureSlot) []const u8 {
    return switch (slot) {
        .base_color => "Albedo and alpha source. When empty, the Base Color and Opacity sliders drive the surface.",
        .metallic_roughness => "Packed metallic/roughness input. Use this when you want authored PBR packing to override scalar sliders.",
        .normal => "Normal map detail for tangent-space lighting. Empty keeps the preview on mesh vertex normals.",
        .occlusion => "Ambient occlusion multiplier used to ground creases and cavities.",
        .emissive => "Self-illumination texture. Without it, the emissive color stays driven by the Emissive control.",
    };
}

fn textureSlotFallbackHint(slot: MaterialTextureSlot) []const u8 {
    return switch (slot) {
        .base_color => "No texture assigned. Renderer falls back to the Base Color and Opacity values.",
        .metallic_roughness => "No texture assigned. Metallic and Roughness sliders are used directly.",
        .normal => "No normal map assigned. Surface shading uses mesh normals only.",
        .occlusion => "No occlusion map assigned. Ambient occlusion contribution stays neutral.",
        .emissive => "No emissive texture assigned. Only the Emissive color contributes.",
    };
}

fn ensureMaterialPreviewCheckerTexture(layer_context: *engine.core.LayerContext) !engine.assets.TextureHandle {
    const checker_name = "__material_preview_checker__";
    for (layer_context.world.assets().textures.items, 0..) |texture, index| {
        if (std.mem.eql(u8, texture.name, checker_name)) {
            return @enumFromInt(index + 1);
        }
    }

    var pixels: [16 * 16 * 4]u8 = undefined;
    var y: usize = 0;
    while (y < 16) : (y += 1) {
        var x: usize = 0;
        while (x < 16) : (x += 1) {
            const tile = ((x / 4) + (y / 4)) % 2 == 0;
            const idx = (y * 16 + x) * 4;
            if (tile) {
                pixels[idx] = 210;
                pixels[idx + 1] = 210;
                pixels[idx + 2] = 210;
                pixels[idx + 3] = 255;
            } else {
                pixels[idx] = 56;
                pixels[idx + 1] = 56;
                pixels[idx + 2] = 56;
                pixels[idx + 3] = 255;
            }
        }
    }

    return try layer_context.world.assets().createTexture(.{
        .name = checker_name,
        .width = 16,
        .height = 16,
        .pixels = pixels[0..],
    });
}
