#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <SDL3/SDL.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  GUAVA_IMGUI_WINDOW_NONE = 0,
  GUAVA_IMGUI_WINDOW_NO_TITLE_BAR = 1 << 0,
  GUAVA_IMGUI_WINDOW_NO_RESIZE = 1 << 1,
  GUAVA_IMGUI_WINDOW_NO_MOVE = 1 << 2,
  GUAVA_IMGUI_WINDOW_NO_SCROLLBAR = 1 << 3,
  GUAVA_IMGUI_WINDOW_NO_SAVED_SETTINGS = 1 << 4,
  GUAVA_IMGUI_WINDOW_NO_DOCKING = 1 << 5,
  GUAVA_IMGUI_WINDOW_NO_COLLAPSE = 1 << 6,
  GUAVA_IMGUI_WINDOW_NO_BACKGROUND = 1 << 7,
  GUAVA_IMGUI_WINDOW_NO_DECORATION = 1 << 8,
  GUAVA_IMGUI_WINDOW_ALWAYS_AUTO_RESIZE = 1 << 9,
  GUAVA_IMGUI_WINDOW_NO_SCROLL_WITH_MOUSE = 1 << 10,
};

enum {
  GUAVA_IMGUI_STYLE_COLOR_TEXT = 0,
  GUAVA_IMGUI_STYLE_COLOR_BUTTON = 1,
  GUAVA_IMGUI_STYLE_COLOR_BUTTON_HOVERED = 2,
  GUAVA_IMGUI_STYLE_COLOR_BUTTON_ACTIVE = 3,
  GUAVA_IMGUI_STYLE_COLOR_HEADER = 10,
  GUAVA_IMGUI_STYLE_COLOR_HEADER_HOVERED = 11,
  GUAVA_IMGUI_STYLE_COLOR_HEADER_ACTIVE = 12,
  GUAVA_IMGUI_STYLE_COLOR_TAB_ACTIVE = 13,
  GUAVA_IMGUI_STYLE_COLOR_TAB_HOVERED = 14,
  GUAVA_IMGUI_STYLE_COLOR_TAB_UNFOCUSED_ACTIVE = 15,
  GUAVA_IMGUI_STYLE_COLOR_SLIDER_GRAB = 16,
  GUAVA_IMGUI_STYLE_COLOR_SLIDER_GRAB_ACTIVE = 17,
  GUAVA_IMGUI_STYLE_COLOR_CHECK_MARK = 18,
  GUAVA_IMGUI_STYLE_COLOR_WINDOW_BG = 19,
  GUAVA_IMGUI_STYLE_COLOR_CHILD_BG = 20,
  GUAVA_IMGUI_STYLE_COLOR_FRAME_BG = 21,
  GUAVA_IMGUI_STYLE_COLOR_SEPARATOR = 22,
  GUAVA_IMGUI_STYLE_COLOR_SEPARATOR_HOVERED = 23,
  GUAVA_IMGUI_STYLE_COLOR_SEPARATOR_ACTIVE = 24,
  GUAVA_IMGUI_STYLE_COLOR_FRAME_BG_HOVERED = 25,
  GUAVA_IMGUI_STYLE_COLOR_FRAME_BG_ACTIVE = 26,
  GUAVA_IMGUI_STYLE_COLOR_BORDER = 27,
  GUAVA_IMGUI_STYLE_COLOR_TEXT_SELECTED_BG = 28,
  GUAVA_IMGUI_STYLE_COLOR_NAV_CURSOR = 29,
  GUAVA_IMGUI_STYLE_COLOR_INPUT_TEXT_CURSOR = 30,
};

enum {
  GUAVA_IMGUI_STYLE_VAR_ALPHA = 0,
  GUAVA_IMGUI_STYLE_VAR_FRAME_PADDING = 1,
  GUAVA_IMGUI_STYLE_VAR_ITEM_SPACING = 2,
  GUAVA_IMGUI_STYLE_VAR_FRAME_ROUNDING = 3,
  GUAVA_IMGUI_STYLE_VAR_WINDOW_MIN_SIZE = 4,
  GUAVA_IMGUI_STYLE_VAR_WINDOW_PADDING = 5,
};

enum {
  GUAVA_IMGUI_INPUT_TEXT_FLAG_NONE = 0,
  GUAVA_IMGUI_INPUT_TEXT_FLAG_ENTER_RETURNS_TRUE = 1 << 6,
};

bool guava_imgui_init(SDL_Window *window, void *metal_bridge_ctx,
                      uint32_t color_target_format);
bool guava_imgui_init_vulkan(SDL_Window *window, void *vk_bridge_ctx);
void guava_imgui_shutdown(void);
void guava_imgui_process_event(const SDL_Event *event);
void guava_imgui_new_frame(void);
void guava_imgui_begin_dockspace(void);
void guava_imgui_reset_default_layout(void);
void guava_imgui_load_animation_layout(void);
void guava_imgui_save_layout(void);
bool guava_imgui_save_layout_to_path(const char *path, size_t path_len);
bool guava_imgui_load_layout_from_path(const char *path, size_t path_len);
void guava_imgui_prepare(void);
void guava_imgui_render(void);
bool guava_imgui_metal_backend_render(void *command_buffer,
                                      void *render_encoder,
                                      void *render_pass_desc);
bool guava_imgui_vulkan_backend_render(void *vk_command_buffer);
bool guava_imgui_want_capture_mouse(void);
bool guava_imgui_want_capture_keyboard(void);
bool guava_imgui_want_text_input(void);

void guava_imgui_get_mouse_pos(float *x, float *y);
void guava_imgui_get_item_rect_min(float *x, float *y);
void guava_imgui_get_item_rect_max(float *x, float *y);
void guava_imgui_draw_list_add_line(float p1_x, float p1_y, float p2_x, float p2_y,
                                    uint32_t color, float thickness);
void guava_imgui_draw_list_add_rect_filled(float p_min_x, float p_min_y,
                                           float p_max_x, float p_max_y,
                                           uint32_t color, float rounding,
                                           uint32_t flags);
void guava_imgui_draw_list_add_circle_filled(float center_x, float center_y,
                                             float radius, uint32_t color,
                                             int32_t num_segments);
void guava_imgui_draw_list_add_text(float pos_x, float pos_y, uint32_t color,
                                    const char *text, size_t text_len);
void guava_imgui_draw_list_add_bezier_curve(
    float p0_x, float p0_y, float cp0_x, float cp0_y, float cp1_x, float cp1_y,
    float p1_x, float p1_y, uint32_t color, float thickness,
    int32_t num_segments);
uint32_t guava_imgui_get_color_u32(float r, float g, float b, float a);
uint32_t guava_imgui_get_color_u32_idx(uint32_t color_idx);

// 游戏内 UI 前景绘图列表 (GR-7)
void guava_imgui_fg_draw_list_add_rect_filled(float p_min_x, float p_min_y,
                                              float p_max_x, float p_max_y,
                                              uint32_t color, float rounding);
void guava_imgui_fg_draw_list_add_text(float pos_x, float pos_y, uint32_t color,
                                       const char *text, size_t text_len);

bool guava_imgui_begin_window(const char *name, size_t name_len);
bool guava_imgui_begin_window_flags(const char *name, size_t name_len,
                                    uint32_t flags);
bool guava_imgui_begin_window_open(const char *name, size_t name_len,
                                   bool *open);
bool guava_imgui_begin_window_flags_open(const char *name, size_t name_len,
                                         bool *open, uint32_t flags);
void guava_imgui_end_window(void);
bool guava_imgui_begin_main_menu_bar(void);
void guava_imgui_end_main_menu_bar(void);
bool guava_imgui_begin_menu(const char *label, size_t label_len);
void guava_imgui_end_menu(void);
void guava_imgui_open_popup(const char *id, size_t id_len);
bool guava_imgui_begin_popup(const char *id, size_t id_len);
bool guava_imgui_is_popup_open(const char *id, size_t id_len);
void guava_imgui_close_current_popup(void);
bool guava_imgui_begin_popup_context_item(const char *id, size_t id_len);
bool guava_imgui_begin_popup_context_window(const char *id, size_t id_len,
                                            bool open_over_items);
void guava_imgui_end_popup(void);
bool guava_imgui_begin_combo(const char *label, size_t label_len,
                             const char *preview, size_t preview_len);
void guava_imgui_end_combo(void);
bool guava_imgui_menu_item(const char *label, size_t label_len,
                           const char *shortcut, size_t shortcut_len,
                           bool selected, bool enabled);
bool guava_imgui_button(const char *label, size_t label_len);
bool guava_imgui_button_ex(const char *label, size_t label_len, float width,
                           float height);
bool guava_imgui_image_button(const char *id, size_t id_len,
                              void *texture, float width,
                              float height, float uv0_x, float uv0_y,
                              float uv1_x, float uv1_y,
                              float bg_r, float bg_g, float bg_b,
                              float bg_a, float tint_r, float tint_g,
                              float tint_b, float tint_a);
bool guava_imgui_invisible_button(const char *id, size_t id_len, float width,
                                  float height);
void guava_imgui_dummy(float width, float height);
void guava_imgui_spacing(void);
void guava_imgui_new_line(void);
void guava_imgui_bullet(void);
void guava_imgui_bullet_text(const char *text, size_t text_len);
void guava_imgui_same_line(void);
void guava_imgui_same_line_ex(float offset_from_start_x, float spacing);
void guava_imgui_separator(void);
void guava_imgui_separator_text(const char *text, size_t text_len);
void guava_imgui_set_next_item_width(float width);
void guava_imgui_set_next_item_open(bool is_open, int32_t cond);
void guava_imgui_set_next_window_pos(float x, float y);
void guava_imgui_set_next_window_size(float width, float height);
void guava_imgui_set_next_window_size_constraints(float min_w, float min_h,
                                                  float max_w, float max_h);
void guava_imgui_set_next_window_bg_alpha(float alpha);
void guava_imgui_push_style_color(uint32_t slot, float r, float g, float b,
                                  float a);
void guava_imgui_pop_style_color(int32_t count);
void guava_imgui_set_style_color(uint32_t color_idx, float r, float g, float b,
                                 float a);
void guava_imgui_set_style_var_float(uint32_t var_idx, float value);
void guava_imgui_push_style_var_float(uint32_t slot, float value);
void guava_imgui_push_style_var_vec2(uint32_t slot, float x, float y);
void guava_imgui_pop_style_var(int32_t count);
bool guava_imgui_begin_child(const char *id, size_t id_len, float width,
                             float height, bool border);
void guava_imgui_end_child(void);
bool guava_imgui_begin_table(const char *id, size_t id_len, int32_t columns);
void guava_imgui_end_table(void);
void guava_imgui_columns(int32_t count, const char *id, size_t id_len, bool border);
void guava_imgui_next_column(void);
void guava_imgui_table_setup_column(const char *label, size_t label_len,
                                    bool stretch, float init_width_or_weight);
void guava_imgui_table_headers_row(void);
void guava_imgui_table_next_row(void);
void guava_imgui_table_next_column(void);
bool guava_imgui_selectable(const char *label, size_t label_len, bool selected,
                            bool span_all_columns, float width, float height);
void guava_imgui_text(const char *text, size_t text_len);
void guava_imgui_text_wrapped(const char *text, size_t text_len);
void guava_imgui_label_text(const char *label, size_t label_len,
                            const char *text, size_t text_len);
void guava_imgui_push_id_u64(uint64_t value);
void guava_imgui_pop_id(void);
bool guava_imgui_tree_node(const char *label, size_t label_len);
bool guava_imgui_tree_node_ex(const char *label, size_t label_len,
                              uint32_t flags);
void guava_imgui_tree_pop(void);
bool guava_imgui_is_item_clicked(void);
bool guava_imgui_is_item_active(void);
bool guava_imgui_is_item_hovered(void);
bool guava_imgui_is_item_deactivated_after_edit(void);
bool guava_imgui_input_text(const char *label, size_t label_len, char *buffer,
                            size_t buffer_size);
bool guava_imgui_input_text_multiline(const char *label, size_t label_len,
                                      char *buffer, size_t buffer_size,
                                      float width, float height);
bool guava_imgui_input_text_with_hint(const char *label, size_t label_len,
                                      const char *hint, size_t hint_len,
                                      char *buffer, size_t buffer_size);
bool guava_imgui_input_text_with_hint_flags(const char *label, size_t label_len,
                                            const char *hint, size_t hint_len,
                                            char *buffer, size_t buffer_size,
                                            uint32_t flags);
bool guava_imgui_input_text_password(const char *label, size_t label_len,
                                     char *buffer, size_t buffer_size);
bool guava_imgui_drag_float(const char *label, size_t label_len, float *value,
                            float speed, float min_value, float max_value);
bool guava_imgui_drag_float3(const char *label, size_t label_len,
                             float value[3], float speed, float min_value,
                             float max_value);
bool guava_imgui_slider_float(const char *label, size_t label_len, float *value,
                              float min_value, float max_value);
bool guava_imgui_slider_angle(const char *label, size_t label_len, float *value_radians,
                              float min_degrees, float max_degrees);
bool guava_imgui_slider_int(const char *label, size_t label_len, int *value,
                            int min_value, int max_value);
bool guava_imgui_input_float(const char *label, size_t label_len, float *value,
                             float step, float step_fast);
bool guava_imgui_input_int(const char *label, size_t label_len, int *value,
                           int step, int step_fast);
bool guava_imgui_checkbox(const char *label, size_t label_len, bool *value);
bool guava_imgui_radio_button(const char *label, size_t label_len, bool active);
void guava_imgui_progress_bar(float fraction, float width, float height,
                              const char *overlay, size_t overlay_len);
bool guava_imgui_collapsing_header(const char *label, size_t label_len,
                                   bool default_open);
bool guava_imgui_begin_drag_drop_source_u64(const char *payload_type,
                                            size_t payload_type_len,
                                            uint64_t value);
void guava_imgui_end_drag_drop_source(void);
bool guava_imgui_drag_drop_source_u64(const char *payload_type,
                                      size_t payload_type_len, uint64_t value,
                                      const char *preview_text,
                                      size_t preview_text_len);
bool guava_imgui_accept_drag_drop_payload_u64(const char *payload_type,
                                              size_t payload_type_len,
                                              uint64_t *out_value);
bool guava_imgui_is_window_hovered(void);
bool guava_imgui_is_window_focused(void);
bool guava_imgui_is_key_pressed(int32_t key, bool repeat);
bool guava_imgui_is_key_down(int32_t key);
bool guava_imgui_is_key_released(int32_t key);
bool guava_imgui_get_key_ctrl(void);
bool guava_imgui_get_key_shift(void);
bool guava_imgui_get_key_alt(void);
void guava_imgui_get_content_region_avail(float out_value[2]);
void guava_imgui_get_window_pos(float out_value[2]);
void guava_imgui_get_cursor_screen_pos(float out_value[2]);
void guava_imgui_set_cursor_pos(float x, float y);
void guava_imgui_set_cursor_pos_y(float y);
void guava_imgui_align_text_to_frame_padding(void);
void guava_imgui_indent(float width);
void guava_imgui_unindent(float width);
void guava_imgui_get_window_size(float out_value[2]);
float guava_imgui_get_font_size(void);
float guava_imgui_get_text_line_height(void);
void guava_imgui_calc_text_size(const char *text, size_t text_len,
                                bool hide_text_after_double_hash,
                                float wrap_width, float out_value[2]);
float guava_imgui_get_frame_height(void);
float guava_imgui_get_time(void);
void guava_imgui_set_scroll_here_y(float center_y_ratio);
void guava_imgui_set_keyboard_focus_here(int32_t offset);
void guava_imgui_set_tooltip(const char *text, size_t text_len);
void guava_imgui_image(void *texture, float width, float height,
                       float uv0_x, float uv0_y, float uv1_x, float uv1_y);
bool guava_imgui_begin_tab_bar(const char *id, size_t id_len);
void guava_imgui_end_tab_bar(void);
bool guava_imgui_begin_tab_item(const char *label, size_t label_len,
                                uint32_t flags);
void guava_imgui_end_tab_item(void);
void guava_imgui_push_clip_rect(float min_x, float min_y, float max_x,
                                float max_y, bool intersect_with_current);
void guava_imgui_pop_clip_rect(void);

// ── Extended widget API ──
bool guava_imgui_drag_float4(const char *label, size_t label_len,
                             float value[4], float speed, float min_value,
                             float max_value);
bool guava_imgui_drag_int(const char *label, size_t label_len, int *value,
                          float speed, int min_value, int max_value);
bool guava_imgui_color_edit3(const char *label, size_t label_len,
                             float color[3]);
bool guava_imgui_color_edit4(const char *label, size_t label_len,
                             float color[4]);
bool guava_imgui_color_picker4(const char *label, size_t label_len,
                               float color[4]);
void guava_imgui_text_colored(float r, float g, float b, float a,
                              const char *text, size_t text_len);
void guava_imgui_begin_group(void);
void guava_imgui_end_group(void);
void guava_imgui_set_item_default_focus(void);
void guava_imgui_set_cursor_screen_pos(float x, float y);
bool guava_imgui_is_mouse_double_clicked(int button);
bool guava_imgui_is_mouse_dragging(int button);
void guava_imgui_get_mouse_drag_delta(int button, float out_value[2]);
void guava_imgui_reset_mouse_drag_delta(int button);

#ifdef __cplusplus
}
#endif
