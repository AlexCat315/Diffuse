const std = @import("std");
const gltf_import = @import("gltf_import.zig");
const registry_mod = @import("registry.zig");
const texture_import = @import("texture_import.zig");

pub const ValidationIssue = struct {
    asset_id: []u8,
    source_path: []u8,
    message: []u8,

    pub fn deinit(self: *ValidationIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.asset_id);
        allocator.free(self.source_path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const ValidationReport = struct {
    asset_count: usize,
    validated_output_count: usize,
    dependency_edge_count: usize,
    issues: []ValidationIssue,

    pub fn ok(self: ValidationReport) bool {
        return self.issues.len == 0;
    }

    pub fn deinit(self: *ValidationReport, allocator: std.mem.Allocator) void {
        for (self.issues) |*issue| {
            issue.deinit(allocator);
        }
        allocator.free(self.issues);
        self.* = undefined;
    }
};

pub fn validateProjectAlloc(allocator: std.mem.Allocator, root_path: []const u8) !ValidationReport {
    var registry = registry_mod.AssetRegistry.init(allocator);
    defer registry.deinit();
    registry.refreshProject(root_path) catch |err| {
        var issues = std.ArrayList(ValidationIssue).empty;
        errdefer {
            for (issues.items) |*issue| {
                issue.deinit(allocator);
            }
            issues.deinit(allocator);
        }

        const message = try std.fmt.allocPrint(allocator, "项目扫描失败: {}", .{err});
        defer allocator.free(message);
        try appendIssue(allocator, &issues, "n/a", root_path, message);
        return .{
            .asset_count = 0,
            .validated_output_count = 0,
            .dependency_edge_count = 0,
            .issues = try issues.toOwnedSlice(allocator),
        };
    };
    return validateRegistryAlloc(allocator, &registry, null);
}

pub fn validateRegistryAlloc(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    query: ?[]const u8,
) !ValidationReport {
    var issues = std.ArrayList(ValidationIssue).empty;
    errdefer {
        for (issues.items) |*issue| {
            issue.deinit(allocator);
        }
        issues.deinit(allocator);
    }

    var asset_count: usize = 0;
    var validated_output_count: usize = 0;

    for (registry.records.items) |record| {
        if (query) |value| {
            if (!std.mem.eql(u8, record.id, value) and !std.mem.eql(u8, record.source_path, value)) {
                continue;
            }
        }

        asset_count += 1;
        try validateRecord(allocator, registry, &record, &validated_output_count, &issues);
    }

    if (query != null and asset_count == 0) {
        try appendIssue(
            allocator,
            &issues,
            "n/a",
            query.?,
            "未找到匹配的资产 ID 或源路径",
        );
    }

    return .{
        .asset_count = asset_count,
        .validated_output_count = validated_output_count,
        .dependency_edge_count = registry.dependencyEdgeCount(),
        .issues = try issues.toOwnedSlice(allocator),
    };
}

fn validateRecord(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    record: *const registry_mod.AssetRecord,
    validated_output_count: *usize,
    issues: *std.ArrayList(ValidationIssue),
) !void {
    if (record.id.len == 0) {
        try appendIssue(allocator, issues, record.id, record.source_path, "资产 ID 为空");
    }
    if (record.source_hash.len == 0) {
        try appendIssue(allocator, issues, record.id, record.source_path, "source_hash 为空");
    }
    if (record.import_settings_hash.len == 0) {
        try appendIssue(allocator, issues, record.id, record.source_path, "import_settings_hash 为空");
    }

    std.fs.cwd().access(record.source_path, .{}) catch {
        try appendIssue(allocator, issues, record.id, record.source_path, "源文件不存在或不可读");
    };

    for (record.dependency_ids) |dependency_id| {
        if (registry.recordById(dependency_id) == null) {
            const message = try std.fmt.allocPrint(allocator, "依赖缺失: {s}", .{dependency_id});
            defer allocator.free(message);
            try appendIssue(allocator, issues, record.id, record.source_path, message);
        }
    }

    const expected_outputs = registry_mod.expectedOutputsAlloc(allocator, record) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "无法计算缓存键: {}", .{err});
        defer allocator.free(message);
        try appendIssue(allocator, issues, record.id, record.source_path, message);
        return;
    };
    defer freeOutputs(allocator, expected_outputs);

    if (!outputsMatch(record.outputs, expected_outputs)) {
        try appendIssue(allocator, issues, record.id, record.source_path, "输出缓存路径与缓存键不一致");
    }

    switch (record.type) {
        .texture => {
            texture_import.validateCookedTextureAsset(allocator, registry, record.id) catch |err| {
                const message = try std.fmt.allocPrint(allocator, "纹理验证失败: {}", .{err});
                defer allocator.free(message);
                try appendIssue(allocator, issues, record.id, record.source_path, message);
                return;
            };
            validated_output_count.* += record.outputs.len;
        },
        .model => {
            gltf_import.validateCookedModelAsset(allocator, registry, record.id) catch |err| {
                const message = try std.fmt.allocPrint(allocator, "模型验证失败: {}", .{err});
                defer allocator.free(message);
                try appendIssue(allocator, issues, record.id, record.source_path, message);
                return;
            };
            validated_output_count.* += record.outputs.len;
        },
        .shader => {
            const bytes = std.fs.cwd().readFileAlloc(allocator, record.source_path, 8 * 1024 * 1024) catch |err| {
                const message = try std.fmt.allocPrint(allocator, "Shader 读取失败: {}", .{err});
                defer allocator.free(message);
                try appendIssue(allocator, issues, record.id, record.source_path, message);
                return;
            };
            defer allocator.free(bytes);
            if (bytes.len == 0) {
                try appendIssue(allocator, issues, record.id, record.source_path, "Shader 源文件为空");
            }
        },
        .scene => {
            const bytes = std.fs.cwd().readFileAlloc(allocator, record.source_path, 32 * 1024 * 1024) catch |err| {
                const message = try std.fmt.allocPrint(allocator, "场景读取失败: {}", .{err});
                defer allocator.free(message);
                try appendIssue(allocator, issues, record.id, record.source_path, message);
                return;
            };
            defer allocator.free(bytes);
            if (bytes.len == 0) {
                try appendIssue(allocator, issues, record.id, record.source_path, "场景文件为空");
            }
        },
        .mesh, .material, .skeleton, .skin, .animation_clip, .script => {
            if (record.metadata.display_name.len == 0) {
                try appendIssue(allocator, issues, record.id, record.source_path, "嵌入资产缺少显示名称");
            }
        },
    }
}

fn outputsMatch(actual: []const registry_mod.AssetOutput, expected: []const registry_mod.AssetOutput) bool {
    if (actual.len != expected.len) {
        return false;
    }
    for (actual, expected) |lhs, rhs| {
        if (lhs.kind != rhs.kind or !std.mem.eql(u8, lhs.path, rhs.path)) {
            return false;
        }
    }
    return true;
}

fn freeOutputs(allocator: std.mem.Allocator, outputs: []registry_mod.AssetOutput) void {
    for (outputs) |*output| {
        output.deinit(allocator);
    }
    allocator.free(outputs);
}

fn appendIssue(
    allocator: std.mem.Allocator,
    issues: *std.ArrayList(ValidationIssue),
    asset_id: []const u8,
    source_path: []const u8,
    message: []const u8,
) !void {
    try issues.append(allocator, .{
        .asset_id = try allocator.dupe(u8, asset_id),
        .source_path = try allocator.dupe(u8, source_path),
        .message = try allocator.dupe(u8, message),
    });
}

test "validator catches missing gltf texture dependency" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.makePath("assets/models");
    try temp_dir.dir.writeFile(.{
        .sub_path = "assets/models/missing_texture.gltf",
        .data =
        \\{
        \\  "asset": { "version": "2.0" },
        \\  "images": [
        \\    { "uri": "checker.png" }
        \\  ]
        \\}
        ,
    });

    const cwd = std.fs.cwd();
    var original = try cwd.openDir(".", .{});
    defer original.close();
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    const report = try validateProjectAlloc(std.testing.allocator, "assets");
    defer {
        var mutable = report;
        mutable.deinit(std.testing.allocator);
    }
    try std.testing.expect(!report.ok());
}
