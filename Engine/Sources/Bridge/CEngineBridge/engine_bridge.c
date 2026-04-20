#include "engine_bridge.h"

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum engine_runtime_phase_t {
    ENGINE_RUNTIME_PHASE_OFFLINE = 0,
    ENGINE_RUNTIME_PHASE_READY = 1,
    ENGINE_RUNTIME_PHASE_INPUT_DONE = 2,
    ENGINE_RUNTIME_PHASE_SIM_DONE = 3,
    ENGINE_RUNTIME_PHASE_RENDER_PREPARE_DONE = 4,
} engine_runtime_phase_t;

typedef struct engine_runtime_state_t {
    bool initialized;
    uint64_t frame_index;
    double total_simulated_seconds;
    double last_delta_time;
    engine_render_replacement_stage_t render_stage;
    engine_runtime_phase_t phase;
} engine_runtime_state_t;

static engine_runtime_state_t g_engine = {
    .initialized = false,
    .frame_index = 0,
    .total_simulated_seconds = 0.0,
    .last_delta_time = 0.0,
    .render_stage = ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE,
    .phase = ENGINE_RUNTIME_PHASE_OFFLINE,
};

static const char *engine_phase_name(engine_runtime_phase_t phase) {
    switch (phase) {
        case ENGINE_RUNTIME_PHASE_OFFLINE:
            return "offline";
        case ENGINE_RUNTIME_PHASE_READY:
            return "ready";
        case ENGINE_RUNTIME_PHASE_INPUT_DONE:
            return "input_done";
        case ENGINE_RUNTIME_PHASE_SIM_DONE:
            return "sim_done";
        case ENGINE_RUNTIME_PHASE_RENDER_PREPARE_DONE:
            return "render_prepare_done";
    }

    return "unknown";
}

static const char *engine_render_stage_name(engine_render_replacement_stage_t stage) {
    switch (stage) {
        case ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE:
            return "R0 rainbow triangle";
        case ENGINE_RENDER_STAGE_R1_MESH_CAMERA:
            return "R1 mesh + camera";
        case ENGINE_RENDER_STAGE_R2_MULTI_OBJECT_DEPTH:
            return "R2 multi-object + depth";
        case ENGINE_RENDER_STAGE_R3_VIEWPORT_INTEROP:
            return "R3 viewport interop";
        case ENGINE_RENDER_STAGE_R4_LIGHTING_PBR_SHADOW:
            return "R4 lighting + PBR + shadow";
        case ENGINE_RENDER_STAGE_R5_POST_PROCESS:
            return "R5 post-process chain";
    }

    return "R0 rainbow triangle";
}

static engine_render_replacement_stage_t parse_render_stage(const char *raw) {
    if (raw == NULL || raw[0] == '\0') {
        return ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE;
    }

    if (strcmp(raw, "0") == 0 || strcmp(raw, "R0") == 0 || strcmp(raw, "r0") == 0) {
        return ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE;
    }
    if (strcmp(raw, "1") == 0 || strcmp(raw, "R1") == 0 || strcmp(raw, "r1") == 0) {
        return ENGINE_RENDER_STAGE_R1_MESH_CAMERA;
    }
    if (strcmp(raw, "2") == 0 || strcmp(raw, "R2") == 0 || strcmp(raw, "r2") == 0) {
        return ENGINE_RENDER_STAGE_R2_MULTI_OBJECT_DEPTH;
    }
    if (strcmp(raw, "3") == 0 || strcmp(raw, "R3") == 0 || strcmp(raw, "r3") == 0) {
        return ENGINE_RENDER_STAGE_R3_VIEWPORT_INTEROP;
    }
    if (strcmp(raw, "4") == 0 || strcmp(raw, "R4") == 0 || strcmp(raw, "r4") == 0) {
        return ENGINE_RENDER_STAGE_R4_LIGHTING_PBR_SHADOW;
    }
    if (strcmp(raw, "5") == 0 || strcmp(raw, "R5") == 0 || strcmp(raw, "r5") == 0) {
        return ENGINE_RENDER_STAGE_R5_POST_PROCESS;
    }

    fprintf(
        stderr,
        "[CEngineBridge] unknown GUAVA_ENGINE_RENDER_STAGE=%s, fallback to R0\n",
        raw);
    return ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE;
}

static double sanitize_delta_time(double delta_time) {
    if (!isfinite(delta_time) || delta_time <= 0.0) {
        return 1.0 / 60.0;
    }

    if (delta_time > 0.25) {
        return 0.25;
    }

    return delta_time;
}

static bool ensure_initialized(const char *fn_name) {
    if (g_engine.initialized) {
        return true;
    }

    fprintf(stderr, "[CEngineBridge] %s ignored: runtime is not initialized\n", fn_name);
    return false;
}

static bool expect_phase(engine_runtime_phase_t expected, const char *fn_name) {
    if (g_engine.phase == expected) {
        return true;
    }

    fprintf(
        stderr,
        "[CEngineBridge] %s ignored: expected phase=%s actual=%s\n",
        fn_name,
        engine_phase_name(expected),
        engine_phase_name(g_engine.phase));
    return false;
}

static bool should_emit_stage_log(void) {
    return g_engine.frame_index == 0 || ((g_engine.frame_index + 1) % 120u) == 0;
}

static void render_prepare_for_stage(double delta_time) {
    (void)delta_time;

    if (!should_emit_stage_log()) {
        return;
    }

    switch (g_engine.render_stage) {
        case ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE:
            printf("[CEngineBridge][R0] prepare: static rainbow triangle resources\n");
            return;
        case ENGINE_RENDER_STAGE_R1_MESH_CAMERA:
            printf("[CEngineBridge][R1] prepare: mesh upload + view/proj uniforms\n");
            return;
        case ENGINE_RENDER_STAGE_R2_MULTI_OBJECT_DEPTH:
            printf("[CEngineBridge][R2] prepare: scene extraction + depth prepass inputs\n");
            return;
        case ENGINE_RENDER_STAGE_R3_VIEWPORT_INTEROP:
            printf("[CEngineBridge][R3] prepare: offscreen viewport texture export\n");
            return;
        case ENGINE_RENDER_STAGE_R4_LIGHTING_PBR_SHADOW:
            printf("[CEngineBridge][R4] prepare: shadow cascade + PBR base uniforms\n");
            return;
        case ENGINE_RENDER_STAGE_R5_POST_PROCESS:
            printf("[CEngineBridge][R5] prepare: post-process graph config (FXAA/SSAO/Bloom)\n");
            return;
    }
}

static void render_submit_for_stage(double delta_time) {
    (void)delta_time;

    if (!should_emit_stage_log()) {
        return;
    }

    switch (g_engine.render_stage) {
        case ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE:
            printf("[CEngineBridge][R0] submit: single pass present\n");
            return;
        case ENGINE_RENDER_STAGE_R1_MESH_CAMERA:
            printf("[CEngineBridge][R1] submit: one mesh draw with camera matrices\n");
            return;
        case ENGINE_RENDER_STAGE_R2_MULTI_OBJECT_DEPTH:
            printf("[CEngineBridge][R2] submit: depth + base pass for multiple objects\n");
            return;
        case ENGINE_RENDER_STAGE_R3_VIEWPORT_INTEROP:
            printf("[CEngineBridge][R3] submit: viewport texture ready for editor sampling\n");
            return;
        case ENGINE_RENDER_STAGE_R4_LIGHTING_PBR_SHADOW:
            printf("[CEngineBridge][R4] submit: shadow pass + PBR base pass\n");
            return;
        case ENGINE_RENDER_STAGE_R5_POST_PROCESS:
            printf("[CEngineBridge][R5] submit: post-process chain + final compose\n");
            return;
    }
}

void engine_init(void) {
    if (g_engine.initialized) {
        fprintf(stderr, "[CEngineBridge] init called twice; keeping existing runtime\n");
        return;
    }

    g_engine.initialized = true;
    g_engine.frame_index = 0;
    g_engine.total_simulated_seconds = 0.0;
    g_engine.last_delta_time = 0.0;
    g_engine.render_stage = parse_render_stage(getenv("GUAVA_ENGINE_RENDER_STAGE"));
    g_engine.phase = ENGINE_RUNTIME_PHASE_READY;

    printf(
        "[CEngineBridge] init: staged runtime enabled, render stage=%s\n",
        engine_render_stage_name(g_engine.render_stage));
}

void engine_tick_input(double delta_time) {
    if (!ensure_initialized("engine_tick_input")
        || !expect_phase(ENGINE_RUNTIME_PHASE_READY, "engine_tick_input")) {
        return;
    }

    g_engine.last_delta_time = sanitize_delta_time(delta_time);
    g_engine.phase = ENGINE_RUNTIME_PHASE_INPUT_DONE;
}

void engine_tick_sim(double delta_time) {
    if (!ensure_initialized("engine_tick_sim")
        || !expect_phase(ENGINE_RUNTIME_PHASE_INPUT_DONE, "engine_tick_sim")) {
        return;
    }

    g_engine.last_delta_time = sanitize_delta_time(delta_time);
    g_engine.total_simulated_seconds += g_engine.last_delta_time;
    g_engine.phase = ENGINE_RUNTIME_PHASE_SIM_DONE;
}

void engine_tick_render_prepare(double delta_time) {
    if (!ensure_initialized("engine_tick_render_prepare")
        || !expect_phase(ENGINE_RUNTIME_PHASE_SIM_DONE, "engine_tick_render_prepare")) {
        return;
    }

    g_engine.last_delta_time = sanitize_delta_time(delta_time);
    render_prepare_for_stage(g_engine.last_delta_time);
    g_engine.phase = ENGINE_RUNTIME_PHASE_RENDER_PREPARE_DONE;
}

void engine_tick_render_submit(double delta_time) {
    if (!ensure_initialized("engine_tick_render_submit")
        || !expect_phase(ENGINE_RUNTIME_PHASE_RENDER_PREPARE_DONE, "engine_tick_render_submit")) {
        return;
    }

    g_engine.last_delta_time = sanitize_delta_time(delta_time);
    render_submit_for_stage(g_engine.last_delta_time);
    g_engine.frame_index += 1;
    g_engine.phase = ENGINE_RUNTIME_PHASE_READY;
}

void engine_shutdown(void) {
    if (!g_engine.initialized) {
        fprintf(stderr, "[CEngineBridge] shutdown ignored: runtime is not initialized\n");
        return;
    }

    printf(
        "[CEngineBridge] shutdown: frames=%llu simulated=%.3fs stage=%s\n",
        (unsigned long long)g_engine.frame_index,
        g_engine.total_simulated_seconds,
        engine_render_stage_name(g_engine.render_stage));

    g_engine = (engine_runtime_state_t){
        .initialized = false,
        .frame_index = 0,
        .total_simulated_seconds = 0.0,
        .last_delta_time = 0.0,
        .render_stage = ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE,
        .phase = ENGINE_RUNTIME_PHASE_OFFLINE,
    };
}
