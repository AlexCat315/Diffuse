#ifndef MOUSE_ENGINE_C_H
#define MOUSE_ENGINE_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MOUSE_ENGINE_API_VERSION 1u

typedef enum mouse_engine_result {
    MOUSE_ENGINE_OK = 0,
    MOUSE_ENGINE_ERROR_INVALID_ARGUMENT = 1,
    MOUSE_ENGINE_ERROR_INVALID_STATE = 2,
    MOUSE_ENGINE_ERROR_RESOURCE_NOT_FOUND = 3,
    MOUSE_ENGINE_ERROR_INTERNAL = 4
} mouse_engine_result;

typedef enum mouse_engine_state {
    MOUSE_ENGINE_STATE_STOPPED = 0,
    MOUSE_ENGINE_STATE_RUNNING = 1,
    MOUSE_ENGINE_STATE_PAUSED = 2
} mouse_engine_state;

typedef struct mouse_engine_config {
    uint32_t api_version;
    uint32_t api_size;
    const char* project_path;
    uint32_t target_fps;
} mouse_engine_config;

typedef struct mouse_engine_info {
    uint32_t api_version;
    uint32_t api_size;
    uint32_t state;
    uint32_t target_fps;
    uint32_t entity_count;
    uint32_t reserved0;
} mouse_engine_info;

typedef struct mouse_engine_scene_desc {
    const char* name;
    const char* path;
} mouse_engine_scene_desc;

void* mouse_engine_create(const mouse_engine_config* config);
void  mouse_engine_destroy(void* engine);
uint32_t mouse_engine_start(void* engine);
uint32_t mouse_engine_stop(void* engine);

mouse_engine_result mouse_engine_get_info(void* engine, mouse_engine_info* out_info);
mouse_engine_result mouse_engine_tick(void* engine, float delta_time);
mouse_engine_result mouse_engine_load_scene(void* engine, const mouse_engine_scene_desc* scene);
mouse_engine_result mouse_engine_unload_scene(void* engine);
mouse_engine_result mouse_engine_get_last_error(void* engine, const char** out_message);

#ifdef __cplusplus
}
#endif

#endif
