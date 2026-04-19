#include "mouse_engine_c.h"

void* mouse_engine_create(const mouse_engine_config* config) {
    (void)config;
    return (void*)0x1;
}

void mouse_engine_destroy(void* engine) {
    (void)engine;
}

uint32_t mouse_engine_start(void* engine) {
    (void)engine;
    return 1u;
}

uint32_t mouse_engine_stop(void* engine) {
    (void)engine;
    return 1u;
}

mouse_engine_result mouse_engine_get_info(void* engine, mouse_engine_info* out_info) {
    if (engine == 0 || out_info == 0) {
        return MOUSE_ENGINE_ERROR_INVALID_ARGUMENT;
    }
    out_info->api_version = MOUSE_ENGINE_API_VERSION;
    out_info->api_size = (uint32_t)sizeof(mouse_engine_info);
    out_info->state = MOUSE_ENGINE_STATE_STOPPED;
    out_info->target_fps = 60u;
    out_info->entity_count = 0u;
    out_info->reserved0 = 0u;
    return MOUSE_ENGINE_OK;
}

mouse_engine_result mouse_engine_tick(void* engine, float delta_time) {
    if (engine == 0 || delta_time < 0.0f) {
        return MOUSE_ENGINE_ERROR_INVALID_ARGUMENT;
    }
    return MOUSE_ENGINE_OK;
}

mouse_engine_result mouse_engine_load_scene(void* engine, const mouse_engine_scene_desc* scene) {
    if (engine == 0 || scene == 0 || scene->path == 0) {
        return MOUSE_ENGINE_ERROR_INVALID_ARGUMENT;
    }
    return MOUSE_ENGINE_OK;
}

mouse_engine_result mouse_engine_unload_scene(void* engine) {
    if (engine == 0) {
        return MOUSE_ENGINE_ERROR_INVALID_ARGUMENT;
    }
    return MOUSE_ENGINE_OK;
}

mouse_engine_result mouse_engine_get_last_error(void* engine, const char** out_message) {
    (void)engine;
    if (out_message == 0) {
        return MOUSE_ENGINE_ERROR_INVALID_ARGUMENT;
    }
    *out_message = "no error";
    return MOUSE_ENGINE_OK;
}
