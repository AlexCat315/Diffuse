# IBL (Image-Based Lighting) 集成指南

本文档描述了如何将IBL系统集成到Guava Engine中，实现基于图像的PBR光照。

## 已完成的组件

### 1. IBL预计算模块 (`src/engine/render/ibl_precompute.zig`)
- **球谐函数(SH9)**：用于高效计算漫反射辐照度
- **Irradiance Map生成**：从HDR环境贴图生成漫反射光照
- **Prefiltered Environment Map生成**：为不同粗糙度预计算镜面反射
- **BRDF LUT生成**：用于分割求和近似（Split-Sum Approximation）

### 2. 环境贴图资源管理 (`src/engine/assets/environment_map_resource.zig`)
- **EnvironmentMapResource**：管理HDR源数据和预计算的IBL贴图
- **IBLCache**：全局管理BRDF LUT

### 3. 环境贴图导入 (`src/engine/assets/environment_map_import.zig`)
- **IBL数据生成**：在HDR导入时自动生成IBL数据
- **缓存管理**：存储和加载预计算的IBL数据

### 4. IBL Shader函数 (`assets/shaders/ibl_pbr.glsl`)
- **GGX分布函数**：用于重要性采样
- **Fresnel-Schlick近似**：计算反射率
- **IBL漫反射**：使用球谐函数计算
- **IBL镜面反射**：使用预过滤环境贴图
- **BRDF LUT采样**：分割求和近似

## 集成步骤

### 步骤1：启用IBL预计算（在texture_import.zig中）

在 `src/engine/assets/texture_import.zig` 的 `cookTextureRecord` 函数中，为HDR文件添加IBL生成：

```zig
// 在cookTextureRecord函数中，修改HDR分支
} else if (std.mem.endsWith(u8, record.source_path, ".hdr")) {
    const encoded = try std.fs.cwd().readFileAlloc(allocator, record.source_path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var decoded = try image_decoder.decodeRgba32f(allocator, encoded);
    defer decoded.deinit();
    width = decoded.width;
    height = decoded.height;
    format = .rgba32_float;
    pixels_hex = try encodeHexAlloc(allocator, std.mem.sliceAsBytes(decoded.pixels));
    
    // >>> 新增：生成IBL数据 <<<
    const env_map_import = @import("environment_map_import.zig");
    const ibl_data_path = try std.fmt.allocPrint(allocator, "{s}_ibl.json", .{cooked_path});
    defer allocator.free(ibl_data_path);
    
    const ibl_data = try env_map_import.generateIBLDataForHDR(
        allocator,
        record.id,
        record.source_path,
        record.source_hash,
        record.import_settings_hash,
        width,
        height,
        decoded.pixels,
    );
    defer allocator.free(ibl_data);
    
    // 保存IBL数据
    if (std.fs.path.dirname(ibl_data_path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }
    try std.fs.cwd().writeFile(.{ .sub_path = ibl_data_path, .data = ibl_data });
}
```

### 步骤2：加载IBL数据到GPU

在 `src/engine/assets/library.zig` 中，添加IBL贴图的加载函数：

```zig
// 在ResourceLibrary中添加
pub fn loadEnvironmentMap(
    self: *ResourceLibrary,
    allocator: std.mem.Allocator,
    registry: *const AssetRegistry,
    asset_id: []const u8,
    device: *rhi_mod.RhiDevice,
) !handles.EnvironmentMapHandle {
    const env_map_import = @import("environment_map_import.zig");
    
    // 确保BRDF LUT存在（全局只生成一次）
    _ = try env_map_import.ensureBRDFLUT(allocator, self, device);
    
    // 加载IBL数据
    const env_map = try env_map_import.loadIBLData(
        allocator,
        self,
        registry,
        asset_id,
        device,
    );
    
    // 存储并返回句柄
    const handle = self.nextEnvironmentMapHandle();
    try self.environment_maps.append(allocator, .{ .handle = handle, .resource = env_map });
    
    return handle;
}
```

### 步骤3：在渲染器中设置IBL贴图

修改 `src/engine/render/renderer.zig`，在渲染前设置IBL贴图：

```zig
// 在prepareScene函数或renderFrame中
fn prepareScene(...) !void {
    // ... existing code ...
    
    // 设置IBL贴图
    if (scene.environment_map) |env_map_handle| {
        const env_map = library.getEnvironmentMap(env_map_handle);
        prepared_scene.irradiance_map = &env_map.irradiance_map;
        prepared_scene.prefiltered_map = &env_map.prefiltered_map;
        prepared_scene.brdf_lut = &library.getBRDFLUT();
    }
}
```

### 步骤4：修改PBR材质Shader

在 `assets/shaders/mesh.frag.glsl` 中，添加IBL光照计算：

```glsl
// 在文件开头添加
#include "ibl_pbr.glsl"

// 在uniforms中添加IBL贴图
layout(set = 2, binding = 0) uniform sampler2D u_irradianceMap;
layout(set = 2, binding = 1) uniform sampler2D u_prefilteredEnvMap;
layout(set = 2, binding = 2) uniform sampler2D u_brdfLUT;
layout(set = 2, binding = 3) uniform sampler2D u_environmentMap; // Fallback

// 在主光照计算函数中
vec3 calculateLighting(PBRData pbr, vec3 N, vec3 V, vec3 world_pos) {
    vec3 result = vec3(0.0);
    
    // Direct lighting (existing code)
    result += calculateDirectLighting(pbr, N, V, world_pos);
    
    // IBL lighting (NEW)
    result += IBL_PBR(N, V, pbr.albedo, pbr.metallic, pbr.roughness);
    
    return result;
}
```

### 步骤5：集成到材质系统

在 `src/engine/assets/material_resource.zig` 中，为材质添加IBL开关：

```zig
pub const MaterialResource = struct {
    // ... existing fields ...
    use_ibl: bool = true,
    ibl_intensity: f32 = 1.0,
};
```

然后在材质编辑器中添加相应的UI控件。

### 步骤6：异步IBL生成

由于IBL预计算可能需要较长时间，建议在JobSystem中异步执行：

```zig
// 在environment_map_import.zig的generateIBLDataForHDR中
pub fn generateIBLDataForHDRAsync(
    allocator: std.mem.Allocator,
    job_system: *JobSystem,
    asset_id: []const u8,
    // ... other params ...
) !*Job {
    const job = try job_system.createJob(
        generateIBLDataJob,
        .{ allocator, asset_id, width, height, hdr_pixels },
    );
    job_system.schedule(job);
    return job;
}
```

## 性能优化建议

### 1. IBL贴图尺寸
- **Irradiance Map**: 64x64 (足够用于漫反射)
- **Prefiltered Map**: 256x256, 5级MIP (平衡质量和内存)
- **BRDF LUT**: 512x512 (只需生成一次，全局共享)

### 2. 缓存策略
- IBL数据应该与源HDR文件一起缓存
- 使用版本号管理缓存失效
- BRDF LUT可以硬编码为引擎内置资源

### 3. GPU格式
- Irradiance/Prefiltered Map: RGBA16_FLOAT (HDR)
- BRDF LUT: RG8_UNORM (存储scale和bias)

### 4. 异步加载
- 在后台线程生成IBL数据
- 使用占位符纹理直到生成完成
- 显示加载进度给用户

## 调试和验证

### 1. 可视化调试
添加调试视图以验证IBL：
- 显示环境贴图
- 显示Irradiance Map
- 显示不同粗糙度的Prefiltered Map
- 显示BRDF LUT

### 2. 单元测试
```zig
test "IBL irradiance calculation" {
    // 测试SH投影是否正确
    // 测试Irradiance Map生成
    // 测试Prefiltered Map生成
}
```

### 3. 验证标准
- 金属度=1.0的物体应该有清晰的反射
- 粗糙度高的物体应该有模糊的反射
- 漫反射应该在各个方向均匀
- 与参考渲染器对比结果

## 后续扩展

### P6: 更高级的IBL技术
- **区域光近似**: 用IBL模拟区域光源
- **动态IBL**: 支持实时光照贴图更新
- **局部IBL**: 为场景不同区域使用不同的IBL体积

### P7: 性能优化
- **IBL LOD**: 基于距离使用不同分辨率的IBL
- **IBL烘焙**: 将IBL数据烘焙到光照贴图
- **Compute Shader**: 使用GPU加速IBL预计算

## 参考资料

1. **Epic Games**: "Real Shading in Unreal Engine 4" (SIGGRAPH 2013)
2. **Google Filament**: "Filament PBR Documentation" 
3. **Sébastien Lagarde**: "Moving Frostbite to Physically Based Rendering" (SIGGRAPH 2014)
4. **IBL Paper**: "Image-based Lighting" by Paul Debevec

## 完成标准

- [ ] HDR环境贴图自动触发IBL预计算
- [ ] Irradiance Map正确生成并用于漫反射
- [ ] Prefiltered Map正确生成并用于镜面反射
- [ ] BRDF LUT生成一次并全局共享
- [ ] 材质Shader集成IBL光照计算
- [ ] 编辑器可以可视化IBL贴图
- [ ] 性能在可接受范围（<1ms per object）
- [ ] 与参考PBR渲染器对比，误差<5%
