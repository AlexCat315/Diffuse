#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GuavaMetalRTContext GuavaMetalRTContext;

/// 纹理元数据 — 描述纹理在打包像素缓冲中的位置/尺寸
typedef struct {
    uint32_t offset;  /* 字节偏移 (BGRA8 像素缓冲) */
    uint32_t width;
    uint32_t height;
    uint32_t format;
} GuavaRTTextureMeta;

typedef enum {
    GUAVA_RT_SAMPLING_TABLE_ENVIRONMENT_IMPORTANCE = 0,
    GUAVA_RT_SAMPLING_TABLE_EMISSIVE_LIGHT = 1,
} GuavaRTSamplingTableKind;

typedef struct {
    uint32_t offset;    /* 字节偏移 (采样表打包缓冲) */
    uint32_t byte_size; /* 该表占用的字节数 */
    uint32_t kind;      /* 见 GuavaRTSamplingTableKind */
    uint32_t _pad;
} GuavaRTSamplingTableMeta;

/// 三角形数据 — 与 Zig RtTriangle / Metal RTTriangle 完全对齐
typedef struct {
    float v0[3], v1[3], v2[3];
    float n0[3], n1[3], n2[3];
    float uv0[2], uv1[2], uv2[2];
    float albedo[3];
    float emissive[3];
    float metallic;
    float roughness;
    float transmission;
    float ior;
    float thickness;
    int32_t base_color_texture_index;
    int32_t metallic_roughness_texture_index;
    int32_t normal_texture_index;
    int32_t occlusion_texture_index;
    int32_t emissive_texture_index;
} GuavaRTTriangle;

/// 光追渲染参数 — 与 Zig RtParams / Metal RTParams 完全对齐
typedef struct {
    float inv_view_projection[16];
    float camera_origin[3];
    float _pad0;
    float light_direction[3];
    float sun_angular_radius;  /* 太阳角半径(弧度)，0=硬阴影 */
    uint32_t width;
    uint32_t height;
    uint32_t samples;
    uint32_t bounces;
    uint32_t mode;             /* 0 = path trace, 1 = shadow only */
    uint32_t shadow_samples;   /* shadow-only 每像素采样数 */
    uint32_t output_is_half;   /* 1 = RGBA16F output, 0 = BGRA8 output */
    int32_t environment_texture_index;
    float exposure_params[4];
    float color_grading_params[4];
    uint32_t directional_light_count;
    uint32_t point_light_count;
    uint32_t spot_light_count;
    uint32_t sampling_table_count;
    float directional_light_directions[4][3];
    float directional_light_radiance[4][3];
    float point_light_positions[16][3];
    float point_light_radiance[16][3];
    float point_light_ranges[16];
    float spot_light_positions[16][3];
    float spot_light_directions[16][3];
    float spot_light_radiance[16][3];
    float spot_light_ranges[16];
    float spot_light_inner_angle_cos[16];
    float spot_light_outer_angle_cos[16];
    uint32_t environment_importance_width;
    uint32_t environment_importance_height;
    float emissive_total_area;
    uint32_t frame_index;  // 渐进式路径追踪帧索引
} GuavaRTParams;

#ifdef __cplusplus
static_assert((sizeof(GuavaRTParams) % 16) == 0,
              "GuavaRTParams must stay 16-byte aligned to match Metal RT argument layout");
#endif

/// 创建 Metal RT 上下文。返回 NULL 表示当前设备不支持 Metal RT。
GuavaMetalRTContext* guava_metal_rt_init(void);

/// 查询是否支持硬件光追。
bool guava_metal_rt_is_supported(GuavaMetalRTContext* ctx);

/// 从三角形数据构建加速结构 (BLAS)。场景变化时调用。
bool guava_metal_rt_build_accel(GuavaMetalRTContext* ctx,
                                const GuavaRTTriangle* triangles,
                                uint32_t triangle_count);

/// 执行光线追踪，将像素写入 output_pixels。
/// output_size = width * height * (mode==1 ? 4 : (output_is_half ? 8 : 4))。
bool guava_metal_rt_trace(GuavaMetalRTContext* ctx,
                          const GuavaRTParams* params,
                          uint8_t* output_pixels,
                          uint32_t output_size);

/// 异步分发光线追踪 (不等待 GPU 完成，立即返回)。
/// 使用 guava_metal_rt_is_trace_complete 轮询完成状态，
/// 使用 guava_metal_rt_get_trace_result 读取结果。
bool guava_metal_rt_trace_async(GuavaMetalRTContext* ctx,
                                const GuavaRTParams* params);

/// 非阻塞轮询：上一次 trace_async 是否已完成。
bool guava_metal_rt_is_trace_complete(GuavaMetalRTContext* ctx);

/// 读取异步 trace 结果到 output_pixels。调用前需确认 is_trace_complete 为 true。
bool guava_metal_rt_get_trace_result(GuavaMetalRTContext* ctx,
                                     uint8_t* output_pixels,
                                     uint32_t output_size);

/// 上传纹理图集数据到 GPU。pixel_data 为所有纹理像素 (BGRA8) 紧密排列，
/// meta 为每张纹理的偏移/尺寸元数据。
bool guava_metal_rt_upload_textures(GuavaMetalRTContext* ctx,
                                    const uint8_t* pixel_data,
                                    uint32_t pixel_data_size,
                                    const GuavaRTTextureMeta* meta,
                                    uint32_t texture_count);

/// 上传环境重要性数据与发光体采样表。
bool guava_metal_rt_upload_sampling_tables(GuavaMetalRTContext* ctx,
                                           const uint8_t* table_data,
                                           uint32_t table_data_size,
                                           const GuavaRTSamplingTableMeta* meta,
                                           uint32_t table_count);

/// 销毁上下文，释放所有 Metal 资源。
void guava_metal_rt_destroy(GuavaMetalRTContext* ctx);

#ifdef __cplusplus
}
#endif
