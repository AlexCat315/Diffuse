const std = @import("std");
const io_globals = @import("io_globals");

pub const current_asset_version: u32 = 2;
pub const current_meta_version: u32 = 1;
pub const snapshot_version: u32 = 1;

pub const AssetType = enum {
    scene,
    model,
    texture,
    shader,
    mesh,
    material,
    skeleton,
    skin,
    animation_clip,
    script,

    pub fn fromPath(path: []const u8) ?AssetType {
        if (std.mem.endsWith(u8, path, ".guava_scene")) {
            return .scene;
        }
        if (std.mem.endsWith(u8, path, ".gltf")) {
            return .model;
        }
        if (std.mem.endsWith(u8, path, ".png") or std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg") or std.mem.endsWith(u8, path, ".svg") or std.mem.endsWith(u8, path, ".hdr")) {
            return .texture;
        }
        if (std.mem.endsWith(u8, path, ".glsl") or std.mem.endsWith(u8, path, ".spv")) {
            return .shader;
        }
        if (std.mem.endsWith(u8, path, ".cs") or std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".csproj")) {
            return .script;
        }
        return null;
    }

    pub fn importerName(self: AssetType) []const u8 {
        return switch (self) {
            .scene => "scene-io-v3",
            .model => "gltf-static-v1",
            .texture => "texture-bgra8-v1",
            .shader => "shader-source-v1",
            .mesh => "embedded-mesh-v1",
            .material => "embedded-material-v1",
            .skeleton => "embedded-skeleton-v1",
            .skin => "embedded-skin-v1",
            .animation_clip => "embedded-animation-clip-v1",
            .script => "embedded-script-v1",
        };
    }

    pub fn importVersion(self: AssetType) u32 {
        return switch (self) {
            .scene => 3,
            .model => 3,
            .texture => 2,
            .shader => 1,
            .mesh => 1,
            .material => 1,
            .skeleton => 1,
            .skin => 1,
            .animation_clip => 1,
            .script => 1,
        };
    }
};

pub const AssetOutput = struct {
    path: []u8,
    kind: AssetType,

    pub fn clone(self: AssetOutput, allocator: std.mem.Allocator) !AssetOutput {
        return .{
            .path = try allocator.dupe(u8, self.path),
            .kind = self.kind,
        };
    }

    pub fn deinit(self: *AssetOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const AssetMetadata = struct {
    display_name: []u8,
    importer: []u8,
    source_extension: []u8,

    pub fn clone(self: AssetMetadata, allocator: std.mem.Allocator) !AssetMetadata {
        return .{
            .display_name = try allocator.dupe(u8, self.display_name),
            .importer = try allocator.dupe(u8, self.importer),
            .source_extension = try allocator.dupe(u8, self.source_extension),
        };
    }

    pub fn deinit(self: *AssetMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.display_name);
        allocator.free(self.importer);
        allocator.free(self.source_extension);
        self.* = undefined;
    }
};

pub const AssetRecord = struct {
    id: []u8,
    type: AssetType,
    source_path: []u8,
    source_hash: []u8,
    import_settings_hash: []u8,
    import_version: u32 = 0,
    dependency_ids: [][]u8,
    outputs: []AssetOutput,
    metadata: AssetMetadata,
    version: u32 = current_asset_version,

    pub fn resolvedImportVersion(self: *const AssetRecord) u32 {
        return if (self.import_version == 0) self.type.importVersion() else self.import_version;
    }

    pub fn clone(self: AssetRecord, allocator: std.mem.Allocator) !AssetRecord {
        const dependency_ids = try cloneStringList(allocator, self.dependency_ids);
        errdefer freeStringList(allocator, dependency_ids);

        const outputs = try allocator.alloc(AssetOutput, self.outputs.len);
        errdefer allocator.free(outputs);
        var output_index: usize = 0;
        errdefer {
            while (output_index > 0) {
                output_index -= 1;
                outputs[output_index].deinit(allocator);
            }
        }
        for (self.outputs, 0..) |output, index| {
            outputs[index] = try output.clone(allocator);
            output_index = index + 1;
        }

        return .{
            .id = try allocator.dupe(u8, self.id),
            .type = self.type,
            .source_path = try allocator.dupe(u8, self.source_path),
            .source_hash = try allocator.dupe(u8, self.source_hash),
            .import_settings_hash = try allocator.dupe(u8, self.import_settings_hash),
            .import_version = self.import_version,
            .dependency_ids = dependency_ids,
            .outputs = outputs,
            .metadata = try self.metadata.clone(allocator),
            .version = self.version,
        };
    }

    pub fn deinit(self: *AssetRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source_path);
        allocator.free(self.source_hash);
        allocator.free(self.import_settings_hash);
        freeStringList(allocator, self.dependency_ids);
        allocator.free(self.dependency_ids);
        for (self.outputs) |*output| {
            output.deinit(allocator);
        }
        allocator.free(self.outputs);
        self.metadata.deinit(allocator);
        self.* = undefined;
    }
};

const MetaFile = struct {
    version: u32 = current_meta_version,
    id: []const u8,
    type: AssetType,
    import_settings_hash: []const u8,
    import_version: u32 = 0,
};

const RegistrySnapshot = struct {
    version: u32 = snapshot_version,
    records: []const AssetRecord,
};

const GltfBuffer = struct {
    uri: ?[]const u8 = null,
};

const GltfImage = struct {
    uri: ?[]const u8 = null,
};

const GltfScanDocument = struct {
    buffers: ?[]GltfBuffer = null,
    images: ?[]GltfImage = null,
};

const SourceDiscovery = struct {
    source_hash: []u8,
    dependency_ids: [][]u8,
};

pub const AssetRegistry = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(AssetRecord) = .empty,
    id_to_index: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator) AssetRegistry {
        return .{
            .allocator = allocator,
            .id_to_index = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *AssetRegistry) void {
        self.clear();
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *AssetRegistry) void {
        for (self.records.items) |*record| {
            record.deinit(self.allocator);
        }
        self.records.clearRetainingCapacity();
    }

    pub fn upsertOwned(self: *AssetRegistry, record: AssetRecord) !*const AssetRecord {
        for (self.records.items) |*existing| {
            if (std.mem.eql(u8, existing.id, record.id)) {
                existing.deinit(self.allocator);
                existing.* = record;
                return existing;
            }
        }
        try self.records.append(self.allocator, record);
        return &self.records.items[self.records.items.len - 1];
    }

    pub fn recordById(self: *const AssetRegistry, id: []const u8) ?*const AssetRecord {
        for (self.records.items) |*record| {
            if (std.mem.eql(u8, record.id, id)) {
                return record;
            }
        }
        return null;
    }

    pub fn recordByPath(self: *const AssetRegistry, source_path: []const u8) ?*const AssetRecord {
        for (self.records.items) |*record| {
            if (std.mem.eql(u8, record.source_path, source_path)) {
                return record;
            }
        }
        return null;
    }

    pub fn cloneRecordById(self: *const AssetRegistry, id: []const u8, allocator: std.mem.Allocator) !?AssetRecord {
        const record = self.recordById(id) orelse return null;
        return try record.clone(allocator);
    }

    pub fn ensureProjectAsset(self: *AssetRegistry, source_path: []const u8) anyerror!*const AssetRecord {
        const normalized_path = try normalizeProjectPath(self.allocator, source_path);
        defer self.allocator.free(normalized_path);

        const asset_type = AssetType.fromPath(normalized_path) orelse return error.UnsupportedAssetType;
        const import_version = asset_type.importVersion();
        const import_settings_hash = try defaultImportSettingsHashAlloc(self.allocator, asset_type);
        defer self.allocator.free(import_settings_hash);

        var meta = try loadOrCreateMetaFile(self.allocator, normalized_path, asset_type, import_settings_hash, import_version);
        defer freeMetaFile(self.allocator, &meta);

        const discovery = try discoverSourceHashAndDependencies(self, normalized_path, asset_type);
        defer self.allocator.free(discovery.source_hash);
        defer self.allocator.free(discovery.dependency_ids);
        defer freeStringList(self.allocator, discovery.dependency_ids);

        const outputs = try defaultOutputsAlloc(self.allocator, asset_type, discovery.source_hash, import_settings_hash, import_version);
        errdefer {
            for (outputs) |*output| {
                output.deinit(self.allocator);
            }
            self.allocator.free(outputs);
        }

        const record = AssetRecord{
            .id = try self.allocator.dupe(u8, meta.id),
            .type = asset_type,
            .source_path = try self.allocator.dupe(u8, normalized_path),
            .source_hash = try self.allocator.dupe(u8, discovery.source_hash),
            .import_settings_hash = try self.allocator.dupe(u8, import_settings_hash),
            .import_version = if (meta.import_version == 0) import_version else meta.import_version,
            .dependency_ids = try cloneStringList(self.allocator, discovery.dependency_ids),
            .outputs = outputs,
            .metadata = .{
                .display_name = try self.allocator.dupe(u8, std.fs.path.basename(normalized_path)),
                .importer = try self.allocator.dupe(u8, asset_type.importerName()),
                .source_extension = try self.allocator.dupe(u8, std.fs.path.extension(normalized_path)),
            },
            .version = current_asset_version,
        };

        return try self.upsertOwned(record);
    }

    pub fn refreshProject(self: *AssetRegistry, root_path: []const u8) anyerror!void {
        self.clear();

        var root_dir = std.Io.Dir.cwd().openDir(io_globals.global_io, root_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                return;
            }
            return err;
        };
        defer root_dir.close(io_globals.global_io);

        var source_paths = std.ArrayList([]u8).empty;
        defer {
            for (source_paths.items) |path| {
                self.allocator.free(path);
            }
            source_paths.deinit(self.allocator);
        }

        var walker = try root_dir.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next(io_globals.global_io)) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            if (std.mem.startsWith(u8, entry.path, "derived/")) {
                continue;
            }
            if (std.mem.endsWith(u8, entry.path, ".meta")) {
                continue;
            }

            const relative = try std.fs.path.join(self.allocator, &.{ root_path, entry.path });
            errdefer self.allocator.free(relative);
            _ = AssetType.fromPath(relative) orelse {
                self.allocator.free(relative);
                continue;
            };
            try source_paths.append(self.allocator, relative);
        }

        std.sort.heap([]u8, source_paths.items, {}, lessThanPath);
        for (source_paths.items) |path| {
            _ = try self.ensureProjectAsset(path);
        }
    }

    pub fn writeSnapshotToPath(self: *const AssetRegistry, path: []const u8) !void {
        const encoded = try self.snapshotJsonAlloc(self.allocator);
        defer self.allocator.free(encoded);

        if (std.fs.path.dirname(path)) |directory| {
            try std.Io.Dir.cwd().createDirPath(io_globals.global_io, directory);
        }
        try std.Io.Dir.cwd().writeFile(io_globals.global_io, .{
            .sub_path = path,
            .data = encoded,
        });
    }

    pub fn snapshotJsonAlloc(self: *const AssetRegistry, allocator: std.mem.Allocator) ![]u8 {
        return try std.json.Stringify.valueAlloc(allocator, RegistrySnapshot{
            .records = self.records.items,
        }, .{ .whitespace = .indent_2 });
    }

    pub fn directDependentsAlloc(self: *const AssetRegistry, allocator: std.mem.Allocator, asset_id: []const u8) ![][]u8 {
        var dependents = std.ArrayList([]u8).empty;
        errdefer {
            for (dependents.items) |dependent_id| {
                allocator.free(dependent_id);
            }
            dependents.deinit(allocator);
        }

        for (self.records.items) |record| {
            for (record.dependency_ids) |dependency_id| {
                if (std.mem.eql(u8, dependency_id, asset_id)) {
                    try dependents.append(allocator, try allocator.dupe(u8, record.id));
                    break;
                }
            }
        }
        return dependents.toOwnedSlice(allocator);
    }

    pub fn transitiveDependentsAlloc(self: *const AssetRegistry, allocator: std.mem.Allocator, asset_id: []const u8) ![][]u8 {
        var visited = std.StringHashMap(void).init(allocator);
        defer {
            var iterator = visited.keyIterator();
            while (iterator.next()) |key| {
                allocator.free(key.*);
            }
            visited.deinit();
        }

        var ordered = std.ArrayList([]u8).empty;
        defer {
            for (ordered.items) |value| {
                allocator.free(value);
            }
            ordered.deinit(allocator);
        }

        try collectTransitiveDependents(self, allocator, asset_id, &visited, &ordered);
        return cloneStringList(allocator, ordered.items);
    }

    pub fn dependencyEdgeCount(self: *const AssetRegistry) usize {
        var count: usize = 0;
        for (self.records.items) |record| {
            count += record.dependency_ids.len;
        }
        return count;
    }
};

pub fn makeDerivedAssetIdAlloc(allocator: std.mem.Allocator, namespace: []const u8, parts: []const []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(namespace);
    for (parts) |part| {
        hasher.update(&.{0});
        hasher.update(part);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexLowerAlloc(allocator, digest[0..16]);
}

pub fn defaultImportSettingsHashAlloc(allocator: std.mem.Allocator, asset_type: AssetType) ![]u8 {
    return hashStringAlloc(allocator, asset_type.importerName());
}

pub fn cacheKeyAlloc(
    allocator: std.mem.Allocator,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    import_version: u32,
) ![]u8 {
    var version_buffer: [16]u8 = undefined;
    const version_text = try std.fmt.bufPrint(&version_buffer, "{d}", .{import_version});
    return hashJoinedAlloc(allocator, "guava.asset.cache.v1", &.{ source_hash, import_settings_hash, version_text });
}

pub fn expectedOutputsAlloc(allocator: std.mem.Allocator, record: *const AssetRecord) ![]AssetOutput {
    return defaultOutputsAlloc(
        allocator,
        record.type,
        record.source_hash,
        record.import_settings_hash,
        record.resolvedImportVersion(),
    );
}

pub fn hashBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return hexLowerAlloc(allocator, digest[0..]);
}

pub fn hashStringAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return hashBytesAlloc(allocator, text);
}

fn hashJoinedAlloc(allocator: std.mem.Allocator, namespace: []const u8, parts: []const []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(namespace);
    for (parts) |part| {
        hasher.update(&.{0});
        hasher.update(part);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexLowerAlloc(allocator, digest[0..]);
}

fn lessThanPath(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn discoverSourceHashAndDependencies(
    registry: *AssetRegistry,
    source_path: []const u8,
    asset_type: AssetType,
) anyerror!SourceDiscovery {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, source_path, registry.allocator, .limited(128 * 1024 * 1024));
    defer registry.allocator.free(bytes);

    switch (asset_type) {
        .model => {
            if (std.mem.endsWith(u8, source_path, ".gltf")) {
                return discoverGltfDependencies(registry, source_path, bytes);
            }
        },
        else => {},
    }

    return .{
        .source_hash = try hashBytesAlloc(registry.allocator, bytes),
        .dependency_ids = try registry.allocator.alloc([]u8, 0),
    };
}

fn discoverGltfDependencies(
    registry: *AssetRegistry,
    source_path: []const u8,
    bytes: []const u8,
) anyerror!SourceDiscovery {
    var parsed = try std.json.parseFromSlice(GltfScanDocument, registry.allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const document = parsed.value;
    const base_dir = std.fs.path.dirname(source_path) orelse ".";

    var dependency_ids = std.ArrayList([]u8).empty;
    errdefer {
        for (dependency_ids.items) |dependency_id| {
            registry.allocator.free(dependency_id);
        }
        dependency_ids.deinit(registry.allocator);
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);

    if (document.buffers) |buffers| {
        for (buffers) |buffer| {
            const uri = buffer.uri orelse continue;
            const buffer_bytes = loadUriBytesAlloc(registry.allocator, base_dir, uri) catch |err| {
                if (err == error.FileNotFound) {
                    std.log.warn("glTF buffer not found: {s} (referenced from {s})", .{ uri, source_path });
                    continue;
                }
                return err;
            };
            defer registry.allocator.free(buffer_bytes);
            hasher.update(&.{0x01});
            hasher.update(buffer_bytes);
        }
    }

    if (document.images) |images| {
        for (images) |image| {
            const uri = image.uri orelse continue;
            if (std.mem.startsWith(u8, uri, "data:")) {
                const image_bytes = try loadUriBytesAlloc(registry.allocator, base_dir, uri);
                defer registry.allocator.free(image_bytes);
                hasher.update(&.{0x02});
                hasher.update(image_bytes);
                continue;
            }

            const dependency_path = try std.fs.path.join(registry.allocator, &.{ base_dir, uri });
            defer registry.allocator.free(dependency_path);
            const dependency_record = registry.ensureProjectAsset(dependency_path) catch |err| {
                if (err == error.FileNotFound) {
                    std.log.warn("glTF image not found: {s} (referenced from {s})", .{ uri, source_path });
                    continue;
                }
                return err;
            };
            try dependency_ids.append(registry.allocator, try registry.allocator.dupe(u8, dependency_record.id));

            const image_bytes = std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, dependency_path, registry.allocator, .limited(128 * 1024 * 1024)) catch |err| {
                if (err == error.FileNotFound) {
                    std.log.warn("glTF image not found: {s} (referenced from {s})", .{ uri, source_path });
                    continue;
                }
                return err;
            };
            defer registry.allocator.free(image_bytes);
            hasher.update(&.{0x03});
            hasher.update(image_bytes);
        }
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{
        .source_hash = try hexLowerAlloc(registry.allocator, digest[0..]),
        .dependency_ids = try dependency_ids.toOwnedSlice(registry.allocator),
    };
}

fn loadOrCreateMetaFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    asset_type: AssetType,
    import_settings_hash: []const u8,
    import_version: u32,
) !MetaFile {
    const meta_path = try std.fmt.allocPrint(allocator, "{s}.meta", .{source_path});
    defer allocator.free(meta_path);

    const encoded = std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, meta_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return createMetaFile(allocator, source_path, asset_type, import_settings_hash, import_version, meta_path),
        else => return err,
    };
    defer allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(MetaFile, allocator, encoded, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var meta = parsed.value;
    if (meta.version == 0) {
        meta.version = current_meta_version;
    }
    if (meta.version != current_meta_version) {
        return error.UnsupportedAssetMetaVersion;
    }

    return .{
        .version = meta.version,
        .id = try allocator.dupe(u8, meta.id),
        .type = meta.type,
        .import_settings_hash = try allocator.dupe(u8, meta.import_settings_hash),
        .import_version = if (meta.import_version == 0) import_version else meta.import_version,
    };
}

fn createMetaFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    asset_type: AssetType,
    import_settings_hash: []const u8,
    import_version: u32,
    meta_path: []const u8,
) !MetaFile {
    const asset_id = try makeDerivedAssetIdAlloc(allocator, "guava.asset.id.v1", &.{ source_path, @tagName(asset_type) });
    defer allocator.free(asset_id);

    const meta = MetaFile{
        .id = asset_id,
        .type = asset_type,
        .import_settings_hash = import_settings_hash,
        .import_version = import_version,
    };
    const encoded = try stringifyAlloc(allocator, meta);
    defer allocator.free(encoded);

    if (std.fs.path.dirname(meta_path)) |directory| {
        try std.Io.Dir.cwd().createDirPath(io_globals.global_io, directory);
    }
    try std.Io.Dir.cwd().writeFile(io_globals.global_io, .{
        .sub_path = meta_path,
        .data = encoded,
    });

    return .{
        .id = try allocator.dupe(u8, asset_id),
        .type = asset_type,
        .import_settings_hash = try allocator.dupe(u8, import_settings_hash),
        .import_version = import_version,
    };
}

fn freeMetaFile(allocator: std.mem.Allocator, meta: *MetaFile) void {
    allocator.free(meta.id);
    allocator.free(meta.import_settings_hash);
    meta.* = undefined;
}

fn defaultOutputsAlloc(
    allocator: std.mem.Allocator,
    asset_type: AssetType,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    import_version: u32,
) ![]AssetOutput {
    const cache_key = try cacheKeyAlloc(allocator, source_hash, import_settings_hash, import_version);
    defer allocator.free(cache_key);

    switch (asset_type) {
        .model => {
            const path = try std.fmt.allocPrint(allocator, "assets/derived/models/{s}-v{d}.guava_scene", .{
                shortHash(cache_key),
                import_version,
            });
            const outputs = try allocator.alloc(AssetOutput, 1);
            outputs[0] = .{
                .path = path,
                .kind = .model,
            };
            return outputs;
        },
        .texture => {
            const path = try std.fmt.allocPrint(allocator, "assets/derived/textures/{s}-v{d}.guava_texture.json", .{
                shortHash(cache_key),
                import_version,
            });
            const outputs = try allocator.alloc(AssetOutput, 1);
            outputs[0] = .{
                .path = path,
                .kind = .texture,
            };
            return outputs;
        },
        else => return allocator.alloc(AssetOutput, 0),
    }
}

fn normalizeProjectPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return allocator.dupe(u8, path);
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
}

fn loadUriBytesAlloc(allocator: std.mem.Allocator, base_dir: []const u8, uri: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, uri, "data:")) {
        const comma_index = std.mem.indexOfScalar(u8, uri, ',') orelse return error.InvalidDataUri;
        const header = uri[0..comma_index];
        if (std.mem.indexOf(u8, header, ";base64") == null) {
            return error.UnsupportedDataUriEncoding;
        }
        const encoded = uri[comma_index + 1 ..];
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const decoded = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(decoded);
        try std.base64.standard.Decoder.decode(decoded, encoded);
        return decoded;
    }

    const resolved = try std.fs.path.join(allocator, &.{ base_dir, uri });
    defer allocator.free(resolved);
    return std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, resolved, allocator, .limited(128 * 1024 * 1024));
}

fn collectTransitiveDependents(
    registry: *const AssetRegistry,
    allocator: std.mem.Allocator,
    asset_id: []const u8,
    visited: *std.StringHashMap(void),
    ordered: *std.ArrayList([]u8),
) !void {
    const direct = try registry.directDependentsAlloc(allocator, asset_id);
    defer {
        freeStringList(allocator, direct);
        allocator.free(direct);
    }

    for (direct) |dependent_id| {
        const owned_id = try allocator.dupe(u8, dependent_id);
        const result = try visited.getOrPut(owned_id);
        if (result.found_existing) {
            allocator.free(owned_id);
            continue;
        }

        try ordered.append(allocator, try allocator.dupe(u8, dependent_id));
        try collectTransitiveDependents(registry, allocator, dependent_id, visited, ordered);
    }
}

fn cloneStringList(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const cloned = try allocator.alloc([]u8, values.len);
    errdefer allocator.free(cloned);

    var index: usize = 0;
    errdefer {
        while (index > 0) {
            index -= 1;
            allocator.free(cloned[index]);
        }
    }
    while (index < values.len) : (index += 1) {
        cloned[index] = try allocator.dupe(u8, values[index]);
    }
    return cloned;
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| {
        allocator.free(value);
    }
}

fn shortHash(hash_hex: []const u8) []const u8 {
    return hash_hex[0..@min(hash_hex.len, 16)];
}

fn hexLowerAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        encoded[index * 2] = nibbleToHexLower(byte >> 4);
        encoded[index * 2 + 1] = nibbleToHexLower(byte & 0x0F);
    }
    return encoded;
}

fn nibbleToHexLower(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

test "project asset registry produces deterministic ids and hashes" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.makePath("assets/textures");
    try temp_dir.dir.writeFile(.{
        .sub_path = "assets/textures/example.png",
        .data = "png",
    });

    const cwd = std.Io.Dir.cwd();
    var original = try cwd.openDir(io_globals.global_io, ".", .{});
    defer original.close(io_globals.global_io);
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    var registry = AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const first = try registry.ensureProjectAsset("assets/textures/example.png");
    const second = try registry.ensureProjectAsset("assets/textures/example.png");
    try std.testing.expectEqualStrings(first.id, second.id);
    try std.testing.expectEqualStrings(first.source_hash, second.source_hash);
    try std.testing.expectEqual(@as(usize, 1), first.outputs.len);
    try std.testing.expect(std.mem.endsWith(u8, first.outputs[0].path, ".guava_texture.json"));
}

test "registry tracks dependency graph and invalidates dependent outputs" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.makePath("assets/models/showcase");
    try temp_dir.dir.writeFile(.{
        .sub_path = "assets/models/showcase/checker.png",
        .data = "texture-a",
    });
    try temp_dir.dir.writeFile(.{
        .sub_path = "assets/models/showcase/showcase.gltf",
        .data =
        \\{
        \\  "asset": { "version": "2.0" },
        \\  "images": [
        \\    { "uri": "checker.png" }
        \\  ]
        \\}
        ,
    });

    const cwd = std.Io.Dir.cwd();
    var original = try cwd.openDir(io_globals.global_io, ".", .{});
    defer original.close(io_globals.global_io);
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    var registry = AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.refreshProject("assets");

    const texture_record = registry.recordByPath("assets/models/showcase/checker.png") orelse return error.AssetNotFound;
    const model_record = registry.recordByPath("assets/models/showcase/showcase.gltf") orelse return error.AssetNotFound;
    const first_output = try std.testing.allocator.dupe(u8, model_record.outputs[0].path);
    defer std.testing.allocator.free(first_output);
    const first_source_hash = try std.testing.allocator.dupe(u8, model_record.source_hash);
    defer std.testing.allocator.free(first_source_hash);

    const dependents = try registry.transitiveDependentsAlloc(std.testing.allocator, texture_record.id);
    defer {
        freeStringList(std.testing.allocator, dependents);
        std.testing.allocator.free(dependents);
    }
    try std.testing.expectEqual(@as(usize, 1), dependents.len);
    try std.testing.expectEqualStrings(model_record.id, dependents[0]);

    try temp_dir.dir.writeFile(.{
        .sub_path = "assets/models/showcase/checker.png",
        .data = "texture-b",
    });
    try registry.refreshProject("assets");

    const updated_model_record = registry.recordByPath("assets/models/showcase/showcase.gltf") orelse return error.AssetNotFound;
    try std.testing.expect(!std.mem.eql(u8, first_source_hash, updated_model_record.source_hash));
    try std.testing.expect(!std.mem.eql(u8, first_output, updated_model_record.outputs[0].path));
}
