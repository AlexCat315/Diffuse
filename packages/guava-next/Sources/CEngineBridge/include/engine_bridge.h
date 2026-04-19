#ifndef ENGINE_BRIDGE_H
#define ENGINE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

void engine_bridge_initialize(void);
void engine_bridge_tick_input(double delta_time);
void engine_bridge_tick_simulation(double delta_time);
void engine_bridge_tick_render_prepare(double delta_time);
void engine_bridge_tick_render_submit(double delta_time);
void engine_bridge_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
