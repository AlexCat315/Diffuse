#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── View Cube ────────────────────────────────────────────────────────────────

enum {
  GUAVA_IMGUI_VIEW_CUBE_NONE = 0,
  GUAVA_IMGUI_VIEW_CUBE_FRONT = 1,
  GUAVA_IMGUI_VIEW_CUBE_BACK = 2,
  GUAVA_IMGUI_VIEW_CUBE_LEFT = 3,
  GUAVA_IMGUI_VIEW_CUBE_RIGHT = 4,
  GUAVA_IMGUI_VIEW_CUBE_TOP = 5,
  GUAVA_IMGUI_VIEW_CUBE_BOTTOM = 6,
  GUAVA_IMGUI_VIEW_CUBE_HOVERED = 1 << 8,
  GUAVA_IMGUI_VIEW_CUBE_ACTIVE = 1 << 9,
  GUAVA_IMGUI_VIEW_CUBE_DRAGGING = 1 << 10,
};

uint32_t guava_imgui_draw_view_cube(const float view[16], float x, float y,
                                    float size, float out_drag_delta[2]);

// ── Tree Node Entity ─────────────────────────────────────────────────────────

enum {
  GUAVA_IMGUI_TREE_NODE_OPEN = 1 << 0,
  GUAVA_IMGUI_TREE_NODE_CLICKED = 1 << 1,
  GUAVA_IMGUI_TREE_NODE_RENAME_COMMITTED = 1 << 2,
  GUAVA_IMGUI_TREE_NODE_RENAME_FINISHED = 1 << 3,
};

/// Draw a tree node with vertical guide lines (VS Code style).
/// @param depth               0 = root, 1 = first child, ...
/// @param ancestor_has_next   per-depth flag: whether ancestor at that depth
///                            has a sibling after it (used to draw vertical
///                            guide lines).  Caller allocates depth+1 entries.
/// @param has_next_sibling    whether this node has a sibling after it
/// @param has_children        true if this node has visible children
/// @param visible             entity visibility flag (for eye icon)
/// @param visible_clicked     out: set to true if visibility toggle was clicked
uint32_t guava_imgui_tree_node_entity(
    uint64_t id, const char *label, size_t label_len, void *icon_texture,
    float icon_size, bool selected, bool leaf, bool default_open,
    char *rename_buffer, size_t rename_buffer_size, bool request_rename_focus,
    int depth, const bool *ancestor_has_next, bool has_next_sibling,
    bool has_children, bool visible, bool *visible_clicked,
    void *chevron_down_texture, void *chevron_right_texture,
    void *eye_texture, void *eye_off_texture, float icon_button_size);

// ── Window Control Button ────────────────────────────────────────────────────

enum {
  GUAVA_IMGUI_WINDOW_CONTROL_MINIMIZE = 0,
  GUAVA_IMGUI_WINDOW_CONTROL_MAXIMIZE = 1,
  GUAVA_IMGUI_WINDOW_CONTROL_CLOSE = 2,
};

bool guava_imgui_window_control_button(uint32_t kind, bool toggled);

#ifdef __cplusplus
}
#endif
