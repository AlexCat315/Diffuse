#include "CoveLog.h"
#include "engine_bridge.h"

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct engine_runtime_state_t {
    bool initialized;
    uint64_t input_frame_count;
    uint64_t sim_frame_count;
    uint64_t prepared_frame_count;
    uint64_t submitted_frame_count;
    double total_simulated_seconds;
    double last_delta_time;
} engine_runtime_state_t;

static engine_runtime_state_t g_engine = {
    .initialized = false,
    .input_frame_count = 0,
    .sim_frame_count = 0,
    .prepared_frame_count = 0,
    .submitted_frame_count = 0,
    .total_simulated_seconds = 0.0,
    .last_delta_time = 0.0,
};

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

    COVE_LOGF(COVE_LOG_WARNING, "com.cove.engine.bridge", "[CEngineBridge] %s ignored: runtime is not initialized\n", fn_name);
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

static bool should_emit_log(uint64_t frame_count) {
    return frame_count == 0 || ((frame_count + 1) % 120u) == 0;
}

void engine_init(void) {
    if (g_engine.initialized) {
        COVE_LOGF(COVE_LOG_WARNING, "com.cove.engine.bridge", "[CEngineBridge] init called twice; keeping existing runtime\n");
        return;
    }

    g_engine.initialized = true;
    COVE_LOGF(COVE_LOG_DEBUG, "com.cove.engine.bridge","[CEngineBridge] init: runtime ready\n");
}

void engine_tick_input(double delta_time) {
    if (!ensure_initialized("engine_tick_input")) {
        return;
    }
    if (!can_tick_input()) {
        COVE_LOGF(COVE_LOG_WARNING, "com.cove.engine.bridge",
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
        COVE_LOGF(COVE_LOG_WARNING, "com.cove.engine.bridge",
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
        COVE_LOGF(COVE_LOG_WARNING, "com.cove.engine.bridge",
                "[CEngineBridge] engine_tick_render_prepare ignored: sim=%llu prepared=%llu\n",
                (unsigned long long)g_engine.sim_frame_count,
                (unsigned long long)g_engine.prepared_frame_count);
        return;
    }

    g_engine.last_delta_time = sanitize_delta_time(delta_time);
    if (should_emit_log(g_engine.prepared_frame_count)) {
        COVE_LOGF(COVE_LOG_DEBUG, "com.cove.engine.bridge","[CEngineBridge] prepare frame=%llu\n",
               (unsigned long long)g_engine.prepared_frame_count);
    }
    g_engine.prepared_frame_count += 1;
}

void engine_tick_render_submit(double delta_time) {
    if (!ensure_initialized("engine_tick_render_submit")) {
        return;
    }
    if (!can_tick_render_submit()) {
        COVE_LOGF(COVE_LOG_WARNING, "com.cove.engine.bridge",
                "[CEngineBridge] engine_tick_render_submit ignored: prepared=%llu submitted=%llu\n",
                (unsigned long long)g_engine.prepared_frame_count,
                (unsigned long long)g_engine.submitted_frame_count);
        return;
    }

    g_engine.last_delta_time = sanitize_delta_time(delta_time);
    if (should_emit_log(g_engine.submitted_frame_count)) {
        COVE_LOGF(COVE_LOG_DEBUG, "com.cove.engine.bridge","[CEngineBridge] submit frame=%llu\n",
               (unsigned long long)g_engine.submitted_frame_count);
    }
    g_engine.submitted_frame_count += 1;
}

void engine_shutdown(void) {
    if (!g_engine.initialized) {
        COVE_LOGF(COVE_LOG_WARNING, "com.cove.engine.bridge", "[CEngineBridge] shutdown ignored: runtime is not initialized\n");
        return;
    }

    COVE_LOGF(COVE_LOG_DEBUG, "com.cove.engine.bridge",
        "[CEngineBridge] shutdown: input=%llu sim=%llu prepared=%llu submitted=%llu simulated=%.3fs\n",
        (unsigned long long)g_engine.input_frame_count,
        (unsigned long long)g_engine.sim_frame_count,
        (unsigned long long)g_engine.prepared_frame_count,
        (unsigned long long)g_engine.submitted_frame_count,
        g_engine.total_simulated_seconds);

    g_engine = (engine_runtime_state_t){
        .initialized = false,
        .input_frame_count = 0,
        .sim_frame_count = 0,
        .prepared_frame_count = 0,
        .submitted_frame_count = 0,
        .total_simulated_seconds = 0.0,
        .last_delta_time = 0.0,
    };
}
