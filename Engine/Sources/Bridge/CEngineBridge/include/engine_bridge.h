#ifndef ENGINE_BRIDGE_H
#define ENGINE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum engine_render_replacement_stage_t {
	ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE = 0,
	ENGINE_RENDER_STAGE_R1_MESH_CAMERA = 1,
	ENGINE_RENDER_STAGE_R2_MULTI_OBJECT_DEPTH = 2,
	ENGINE_RENDER_STAGE_R3_VIEWPORT_INTEROP = 3,
	ENGINE_RENDER_STAGE_R4_LIGHTING_PBR_SHADOW = 4,
	ENGINE_RENDER_STAGE_R5_POST_PROCESS = 5,
} engine_render_replacement_stage_t;

void engine_init(void);
void engine_tick_input(double delta_time);
void engine_tick_sim(double delta_time);
void engine_tick_render_prepare(double delta_time);
void engine_tick_render_submit(double delta_time);
void engine_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
