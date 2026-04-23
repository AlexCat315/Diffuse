#include "engine_bridge.h"

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct engine_runtime_state_t {
    bool initialized;
    uint64_t input_frame_count;
    uint64_t sim_frame_count;
    uint64_t prepared_frame_count;
    uint64_t submitted_frame_count;
    double total_simulated_seconds;
    double last_delta_time;
    engine_render_replacement_stage_t render_stage;
} engine_runtime_state_t;

static engine_runtime_state_t g_engine = {
    .initialized = false,
    .input_frame_count = 0,
    .sim_frame_count = 0,
    .prepared_frame_count = 0,
    .submitted_frame_count = 0,
    .total_simulated_seconds = 0.0,
    .last_delta_time = 0.0,
    .render_stage = ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE,
};

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

static bool can_tick_input(void) {
    return g_engine.input_frame_count == g_engine.sim_frame_count;
}

static bool can_tick_sim(void) {
    return g_engine.input_frame_count > g_engine.sim_frame_count;
}

static bool can_tick_render_prepare(void) {
    return g_engine.sim_frame_count > g_engine.prepared_frame_count;
}

static bool can_tick_render_submit(void) {
    return g_engine.prepared_frame_count > g_engine.submitted_frame_count;
}

static bool should_emit_stage_log(uint64_t frame_count) {
    return frame_count == 0 || ((frame_count + 1) % 120u) == 0;
}

static void render_prepare_for_stage(double delta_time) {
    (void)delta_time;
    uint64_t frame_index = g_engine.prepared_frame_count;

    if (!should_emit_stage_log(frame_index)) {
        return;
    }

    switch (g_engine.render_stage) {
        case ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE:
            printf("[CEngineBridge][R0] prepare frame=%llu: static rainbow triangle resources\n",
                   (unsigned long long)frame_index);
            return;
        case ENGINE_RENDER_STAGE_R1_MESH_CAMERA:
            printf("[CEngineBridge][R1] prepare frame=%llu: mesh upload + view/proj uniforms\n",
                   (unsigned long long)frame_index);
            return;
        case ENGINE_RENDER_STAGE_R2_MULTI_OBJECT_DEPTH:
            printf("[CEngineBridge][R2] prepare frame=%llu: scene extraction + depth prepass inputs\n",
                   (unsigned long long)frame_index);
            return;
        case ENGINE_RENDER_STAGE_R3_VIEWPORT_INTEROP:
            printf("[CEngineBridge][R3] prepare frame=%llu: offscreen viewport texture export\n",
                   (unsigned long long)frame_index);
            return;
        case ENGINE_RENDER_STAGE_R4_LIGHTING_PBR_SHADOW:
            printf("[CEngineBridge][R4] prepare frame=%llu: shadow cascade + PBR base uniforms\n",
                   (unsigned long long)frame_index);
            return;
        case ENGINE_RENDER_STAGE_R5_POST_PROCESS:
            printf("[CEngineBridge][R5] prepare frame=%llu: post-process graph config (FXAA/SSAO/Bloom)\n",
                   (unsigned long long)frame_index);
            return;
    }
}

static void render_submit_for_stage(double delta_time) {
    (void)delta_time;
    uint64_t frame_index = g_engine.submitted_frame_count;

    if (!should_emit_stage_log(frame_index)) {
        return;
    }

    switch (g_engine.render_stage) {
        case ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE:
            printf("[CEngineBridge][R0] submit frame=%llu: single pass present\n",
                   (unsigned long long)frame_index);
            return;
        case ENGINE_RENDER_STAGE_R1_MESH_CAMERA:
            printf("[CEngineBridge][R1] submit frame=%llu: one mesh draw with camera matrices\n",
                   (unsigned long long)frame_index);
            return;
        case ENGINE_RENDER_STAGE_R2_MULTI_OBJECT_DEPTH:
            printf("[CEngineBridge][R2] submit frame=%llu: depth + base pass for multiple objects\n",
                   (unsigned long long)frame_index);
            return;
        case ENGINE_RENDER_STAGE_R3_VIEWPORT_INTEROP:
            printf("[CEngineBridge][R3] submit frame=%llu: viewport texture ready for editor sampling\n",
                   (unsigned long long)frame_index);
            return;
        case ENGINE_RENDER_STAGE_R4_LIGHTING_PBR_SHADOW:
            printf("[CEngineBridge][R4] submit frame=%llu: shadow pass + PBR base pass\n",
                   (unsigned long long)frame_index);
            return;
        case ENGINE_RENDER_STAGE_R5_POST_PROCESS:
            printf("[CEngineBridge][R5] submit frame=%llu: post-process chain + final compose\n",
                   (unsigned long long)frame_index);
            return;
    }
}

void engine_init(void) {
    if (g_engine.initialized) {
        fprintf(stderr, "[CEngineBridge] init called twice; keeping existing runtime\n");
        return;
    }

    g_engine.initialized = true;
    g_engine.input_frame_count = 0;
    g_engine.sim_frame_count = 0;
    g_engine.prepared_frame_count = 0;
    g_engine.submitted_frame_count = 0;
    g_engine.total_simulated_seconds = 0.0;
    g_engine.last_delta_time = 0.0;
    g_engine.render_stage = parse_render_stage(getenv("GUAVA_ENGINE_RENDER_STAGE"));

    printf(
        "[CEngineBridge] init: staged runtime enabled, render stage=%s\n",
        engine_render_stage_name(g_engine.render_stage));
}

void engine_tick_input(double delta_time) {
    if (!ensure_initialized("engine_tick_input")) {
        return;
    }
    if (!can_tick_input()) {
        fprintf(stderr,
                "[CEngineBridge] engine_tick_input ignored: input=%llu sim=%llu\n",
                (unsigned long long)g_engine.input_frame_count,
                (unsigned long long)g_engine.sim_frame_count);
        return;
    }

    g_engine.last_delta_time = sanitize_delta_time(delta_time);
    g_engine.input_frame_count += 1;
}

void engine_tick_sim(double delta_time) {
    if (!ensure_initialized("engine_tick_sim")) {
        return;
    }
    if (!can_tick_sim()) {
        fprintf(stderr,
                "[CEngineBridge] engine_tick_sim ignored: input=%llu sim=%llu\n",
                (unsigned long long)g_engine.input_frame_count,
                (unsigned long long)g_engine.sim_frame_count);
        return;
    }

    g_engine.last_delta_time = sanitize_delta_time(delta_time);
    g_engine.total_simulated_seconds += g_engine.last_delta_time;
    g_engine.sim_frame_count += 1;
}

void engine_tick_render_prepare(double delta_time) {
    if (!ensure_initialized("engine_tick_render_prepare")) {
        return;
    }
    if (!can_tick_render_prepare()) {
        fprintf(stderr,
                "[CEngineBridge] engine_tick_render_prepare ignored: sim=%llu prepared=%llu\n",
                (unsigned long long)g_engine.sim_frame_count,
                (unsigned long long)g_engine.prepared_frame_count);
        return;
    }

    g_engine.last_delta_time = sanitize_delta_time(delta_time);
    render_prepare_for_stage(g_engine.last_delta_time);
    g_engine.prepared_frame_count += 1;
}

void engine_tick_render_submit(double delta_time) {
    if (!ensure_initialized("engine_tick_render_submit")) {
        return;
    }
    if (!can_tick_render_submit()) {
        fprintf(stderr,
                "[CEngineBridge] engine_tick_render_submit ignored: prepared=%llu submitted=%llu\n",
                (unsigned long long)g_engine.prepared_frame_count,
                (unsigned long long)g_engine.submitted_frame_count);
        return;
    }

    g_engine.last_delta_time = sanitize_delta_time(delta_time);
    render_submit_for_stage(g_engine.last_delta_time);
    g_engine.submitted_frame_count += 1;
}

void engine_shutdown(void) {
    if (!g_engine.initialized) {
        fprintf(stderr, "[CEngineBridge] shutdown ignored: runtime is not initialized\n");
        return;
    }

    printf(
        "[CEngineBridge] shutdown: input=%llu sim=%llu prepared=%llu submitted=%llu simulated=%.3fs stage=%s\n",
        (unsigned long long)g_engine.input_frame_count,
        (unsigned long long)g_engine.sim_frame_count,
        (unsigned long long)g_engine.prepared_frame_count,
        (unsigned long long)g_engine.submitted_frame_count,
        g_engine.total_simulated_seconds,
        engine_render_stage_name(g_engine.render_stage));

    g_engine = (engine_runtime_state_t){
        .initialized = false,
        .input_frame_count = 0,
        .sim_frame_count = 0,
        .prepared_frame_count = 0,
        .submitted_frame_count = 0,
        .total_simulated_seconds = 0.0,
        .last_delta_time = 0.0,
        .render_stage = ENGINE_RENDER_STAGE_R0_RAINBOW_TRIANGLE,
    };
}
