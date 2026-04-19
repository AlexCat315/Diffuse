#ifndef ENGINE_BRIDGE_H
#define ENGINE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

void engine_bridge_initialize(void);
void engine_bridge_update(double delta_time);
void engine_bridge_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
