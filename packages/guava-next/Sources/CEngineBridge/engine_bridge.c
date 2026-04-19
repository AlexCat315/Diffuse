#include "engine_bridge.h"
#include <stdio.h>

void engine_bridge_initialize(void) {
    printf("[CEngineBridge] initialize\n");
}

void engine_bridge_update(double delta_time) {
    (void)delta_time;
}

void engine_bridge_shutdown(void) {
    printf("[CEngineBridge] shutdown\n");
}
