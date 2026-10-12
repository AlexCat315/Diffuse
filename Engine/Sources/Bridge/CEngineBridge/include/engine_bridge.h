#ifndef ENGINE_BRIDGE_H
#define ENGINE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

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
