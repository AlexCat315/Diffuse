#include "imgui_widgets.h"

#include <algorithm>
#include <cmath>
#include <string>

#include "imgui.h"
#include "imgui_internal.h"

// ── Shared state ─────────────────────────────────────────────────────────────

extern bool g_imgui_initialized;

namespace {

std::string make_string(const char* text, size_t text_len) {
  return std::string(text, text_len);
}

ImU32 scale_color(ImU32 color, float factor) {
  const int r =
      (std::min)(255, static_cast<int>(((color >> IM_COL32_R_SHIFT) & 0xff) *
                                       factor));
  const int g =
      (std::min)(255, static_cast<int>(((color >> IM_COL32_G_SHIFT) & 0xff) *
                                       factor));
  const int b =
      (std::min)(255, static_cast<int>(((color >> IM_COL32_B_SHIFT) & 0xff) *
                                       factor));
  const int a = static_cast<int>((color >> IM_COL32_A_SHIFT) & 0xff);
  return IM_COL32(r, g, b, a);
}

float distance_squared(ImVec2 a, ImVec2 b) {
  const float dx = a.x - b.x;
  const float dy = a.y - b.y;
  return dx * dx + dy * dy;
}

// ── Window Control Button helpers ────────────────────────────────────────────

void draw_window_control_icon(ImDrawList* draw_list, ImRect rect, uint32_t kind,
                              bool toggled, ImU32 color) {
  const ImVec2 center = rect.GetCenter();
  const float half_w = rect.GetWidth() * 0.18f;
  const float half_h = rect.GetHeight() * 0.18f;
  const float thickness = 1.5f;

  switch (kind) {
    case GUAVA_IMGUI_WINDOW_CONTROL_MINIMIZE:
      draw_list->AddLine(ImVec2(center.x - half_w, center.y + half_h * 0.45f),
                         ImVec2(center.x + half_w, center.y + half_h * 0.45f),
                         color, thickness);
      break;
    case GUAVA_IMGUI_WINDOW_CONTROL_MAXIMIZE:
      if (toggled) {
        draw_list->AddRect(
            ImVec2(center.x - half_w * 0.55f, center.y - half_h * 1.25f),
            ImVec2(center.x + half_w * 1.05f, center.y + half_h * 0.35f),
            color, 1.5f, 0, thickness);
        draw_list->AddRect(
            ImVec2(center.x - half_w * 1.05f, center.y - half_h * 0.35f),
            ImVec2(center.x + half_w * 0.55f, center.y + half_h * 1.25f),
            color, 1.5f, 0, thickness);
      } else {
        draw_list->AddRect(ImVec2(center.x - half_w, center.y - half_h),
                           ImVec2(center.x + half_w, center.y + half_h), color,
                           1.5f, 0, thickness);
      }
      break;
    case GUAVA_IMGUI_WINDOW_CONTROL_CLOSE:
      draw_list->AddLine(ImVec2(center.x - half_w, center.y - half_h),
                         ImVec2(center.x + half_w, center.y + half_h), color,
                         thickness);
      draw_list->AddLine(ImVec2(center.x - half_w, center.y + half_h),
                         ImVec2(center.x + half_w, center.y - half_h), color,
                         thickness);
      break;
    default:
      break;
  }
}

// ── View Cube helpers ────────────────────────────────────────────────────────

struct ViewCubePoint3 {
  float x;
  float y;
  float z;
};

struct ViewCubePoint2 {
  float x;
  float y;
};

struct ViewCubeFaceInfo {
  uint32_t id;
  const char* label;
  ViewCubePoint3 normal;
  int corners[4];
  ImU32 color;
};

struct ViewCubeAxisInfo {
  uint32_t id;
  const char* label;
  ViewCubePoint3 direction;
  ImU32 color;
  bool positive;
};

struct ViewCubeAxisHandle {
  uint32_t id;
  const char* label;
  ImU32 color;
  bool positive;
  ImVec2 center;
  float radius;
  float depth;
};

ViewCubePoint3 rotate_by_view(const float view[16], ViewCubePoint3 point) {
  return {
      view[0] * point.x + view[4] * point.y + view[8] * point.z,
      view[1] * point.x + view[5] * point.y + view[9] * point.z,
      view[2] * point.x + view[6] * point.y + view[10] * point.z,
  };
}

ViewCubePoint2 project_view_cube_point(ViewCubePoint3 point, ImVec2 center,
                                       float radius) {
  constexpr float viewer_distance = 4.5f;
  const float denom = (std::max)(viewer_distance - point.z, 0.8f);
  return {
      center.x + point.x * radius / denom,
      center.y - point.y * radius / denom,
  };
}

ViewCubePoint3 scale_point3(ViewCubePoint3 point, float factor) {
  return {
      point.x * factor,
      point.y * factor,
      point.z * factor,
  };
}

ImVec2 to_imvec2(ViewCubePoint2 point) { return ImVec2(point.x, point.y); }

}  // namespace

// ═══════════════════════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════════════════════

extern "C" bool guava_imgui_window_control_button(uint32_t kind, bool toggled) {
  if (!g_imgui_initialized) {
    return false;
  }

  const float height = ImGui::GetFrameHeight();
  const ImVec2 size(height * 1.42f, height * 0.9f);
  const float rounding = 6.0f;
  ImGui::PushID(static_cast<int>(kind));
  const bool clicked = ImGui::InvisibleButton("##window_control", size);

  const bool hovered = ImGui::IsItemHovered();
  const bool active = ImGui::IsItemActive();
  const ImRect rect(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
  ImDrawList* draw_list = ImGui::GetWindowDrawList();

  ImU32 bg_color = IM_COL32(0, 0, 0, 0);
  ImU32 border_color = IM_COL32(136, 150, 172, 42);
  if (kind == GUAVA_IMGUI_WINDOW_CONTROL_CLOSE) {
    if (active) {
      bg_color = IM_COL32(172, 44, 49, 255);
      border_color = IM_COL32(217, 111, 116, 110);
    } else if (hovered) {
      bg_color = IM_COL32(208, 64, 72, 245);
      border_color = IM_COL32(242, 149, 152, 120);
    }
  } else {
    if (active) {
      bg_color = IM_COL32(82, 92, 112, 176);
      border_color = IM_COL32(168, 180, 198, 92);
    } else if (hovered) {
      bg_color = IM_COL32(60, 71, 88, 132);
      border_color = IM_COL32(160, 174, 194, 88);
    } else {
      bg_color = IM_COL32(255, 255, 255, 8);
    }
  }

  if ((bg_color & IM_COL32_A_MASK) != 0) {
    draw_list->AddRectFilled(rect.Min, rect.Max, bg_color, rounding);
  }
  if ((border_color & IM_COL32_A_MASK) != 0) {
    draw_list->AddRect(rect.Min, rect.Max, border_color, rounding);
  }

  const ImU32 icon_color = hovered || active ? IM_COL32(245, 247, 250, 255)
                                             : IM_COL32(176, 188, 207, 212);
  draw_window_control_icon(draw_list, rect, kind, toggled, icon_color);

  ImGui::PopID();
  return clicked;
}

extern "C" uint32_t guava_imgui_tree_node_entity(
    uint64_t id, const char* label, size_t label_len, void* icon_texture,
    float icon_size, bool selected, bool leaf, bool default_open,
    char* rename_buffer, size_t rename_buffer_size, bool request_rename_focus,
    int depth, const bool* ancestor_has_next, bool has_next_sibling,
    bool has_children, bool visible, bool* visible_clicked,
    void* chevron_down_texture, void* chevron_right_texture,
    void* eye_texture, void* eye_off_texture, float icon_button_size) {
  if (!g_imgui_initialized) {
    return 0;
  }
  if (visible_clicked) *visible_clicked = false;

  ImGui::PushID(static_cast<int>(id));

  // ── Constants ───────────────────────────────────────────────────────────
  const float indent = 20.0f;
  const float row_height = ImGui::GetFontSize() + 8.0f;
  const float rounding = 4.0f;
  ImDrawList* draw_list = ImGui::GetWindowDrawList();
  const ImVec2 window_pos = ImGui::GetWindowPos();
  const float content_left = window_pos.x + ImGui::GetWindowContentRegionMin().x;
  const float content_right = window_pos.x + ImGui::GetWindowContentRegionMax().x;

  // ── Eye button area (right-aligned, separate from row background) ───────
  const float eye_button_area_width = icon_button_size + 12.0f;
  const float eye_button_area_left = content_right - eye_button_area_width;

  // ── Reserve row space ───────────────────────────────────────────────────
  const ImVec2 cursor = ImGui::GetCursorScreenPos();
  const float row_top = cursor.y;
  const float row_center_y = row_top + row_height * 0.5f;

  ImGui::Dummy(ImVec2(content_right - content_left, row_height));
  const ImVec2 item_min = ImGui::GetItemRectMin();
  const ImVec2 item_max = ImGui::GetItemRectMax();

  // ── Open state from storage ─────────────────────────────────────────────
  ImGuiStorage* storage = ImGui::GetStateStorage();
  ImGuiID open_id = ImGui::GetID("##open");
  bool is_open = storage->GetInt(open_id, default_open ? 1 : 0) != 0;

  // ── Hover state ─────────────────────────────────────────────────────────
  const bool hovered = ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem);

  // ── Row background (only in content area, NOT covering eye button) ──────
  if (selected) {
    draw_list->AddRectFilled(
        ImVec2(content_left, item_min.y + 1.0f),
        ImVec2(eye_button_area_left, item_max.y - 1.0f),
        IM_COL32(40, 80, 90, 240), rounding);
  } else if (hovered) {
    draw_list->AddRectFilled(
        ImVec2(content_left, item_min.y + 1.0f),
        ImVec2(eye_button_area_left, item_max.y - 1.0f),
        IM_COL32(255, 255, 255, 15), rounding);
  }

  // ── Selection accent bar (left edge) ────────────────────────────────────
  if (selected) {
    draw_list->AddRectFilled(
        ImVec2(content_left, item_min.y),
        ImVec2(content_left + 3.0f, item_max.y),
        IM_COL32(86, 200, 250, 255), 2.0f);
  }

  // ── Guide lines (L/T-shaped connectors) ─────────────────────────────────
  const ImU32 guide_color = IM_COL32(70, 76, 90, 200);
  const ImU32 guide_color_active = IM_COL32(90, 98, 115, 240);
  const float guide_thickness = 1.0f;
  const ImU32 col = (selected || hovered) ? guide_color_active : guide_color;
  const float overlap = 3.0f;

  // Vertical lines for ancestor levels — extend beyond row bounds so
  // adjacent rows blend into a single continuous line
  for (int d = 0; d < depth; ++d) {
    if (ancestor_has_next != nullptr && ancestor_has_next[d]) {
      const float line_x = content_left + indent * (d + 1) - indent * 0.5f;
      draw_list->AddLine(
          ImVec2(line_x, item_min.y - overlap),
          ImVec2(line_x, item_max.y + overlap),
          col, guide_thickness);
    }
  }

  // ── Calculate base x position ───────────────────────────────────────────
  float x_offset = content_left + depth * indent;

  // L/T-shaped connector for current node (depth > 0)
  // Vertical segment sits at the SAME x as the ancestor guide line for
  // this depth level, so they visually merge into one continuous line.
  if (depth > 0) {
    const float vert_x = content_left + indent * depth - indent * 0.5f;
    const float horiz_end = x_offset + icon_button_size * 0.5f;

    // Vertical: from above row top down to center
    draw_list->AddLine(
        ImVec2(vert_x, item_min.y - overlap),
        ImVec2(vert_x, row_center_y),
        col, guide_thickness);
    // Horizontal: from vertical line to chevron center
    draw_list->AddLine(
        ImVec2(vert_x, row_center_y),
        ImVec2(horiz_end, row_center_y),
        col, guide_thickness);
  }

  // Extend vertical below center when this node has following siblings
  // ┬ shape (├) vs └ shape (last child)
  if (has_next_sibling) {
    const float vert_x = content_left + indent * depth - indent * 0.5f;
    draw_list->AddLine(
        ImVec2(vert_x, row_center_y),
        ImVec2(vert_x, item_max.y + overlap),
        col, guide_thickness);
  }

  // ── Chevron (expand/collapse) using SVG icon ────────────────────────────
  void* chevron_tex = nullptr;
  if (has_children) {
    chevron_tex = is_open ? chevron_down_texture : chevron_right_texture;
  }
  if (chevron_tex != nullptr && icon_button_size > 0.0f) {
    const ImVec2 chev_min(x_offset, row_top + (row_height - icon_button_size) * 0.5f);
    const ImVec2 chev_max(chev_min.x + icon_button_size, chev_min.y + icon_button_size);
    draw_list->AddImage(reinterpret_cast<ImTextureID>(chevron_tex), chev_min, chev_max);
    x_offset += icon_button_size + 2.0f;
  } else {
    x_offset += icon_button_size + 2.0f;
  }

  // ── Entity icon ─────────────────────────────────────────────────────────
  if (icon_texture != nullptr && icon_size > 0.0f) {
    const float draw_size = (std::min)(icon_size, row_height - 4.0f);
    const ImVec2 icon_min(x_offset, row_top + (row_height - draw_size) * 0.5f);
    const ImVec2 icon_max(icon_min.x + draw_size, icon_min.y + draw_size);
    draw_list->AddImage(reinterpret_cast<ImTextureID>(icon_texture), icon_min, icon_max);
    x_offset += draw_size + 5.0f;
  } else {
    x_offset += 3.0f;
  }

  // ── Label text ──────────────────────────────────────────────────────────
  const float text_y = row_top + (row_height - ImGui::GetFontSize()) * 0.5f;
  const float max_text_x = eye_button_area_left - 8.0f;

  ImU32 text_color;
  if (selected) {
    text_color = IM_COL32(240, 248, 255, 255);
  } else if (!visible) {
    text_color = IM_COL32(90, 100, 115, 140);
  } else {
    text_color = IM_COL32(210, 220, 235, 255);
  }

  if (x_offset < max_text_x) {
    const std::string owned_label = make_string(label, label_len);
    draw_list->AddText(ImVec2(x_offset, text_y), text_color, owned_label.c_str());
  }

  // ── Eye button (visibility toggle, separate from row background) ────────
  const ImVec2 eye_min(eye_button_area_left + 6.0f, row_top + (row_height - icon_button_size) * 0.5f);

  ImGui::SetCursorScreenPos(eye_min);
  ImGui::InvisibleButton("##eye", ImVec2(icon_button_size, icon_button_size));
  const bool eye_hovered = ImGui::IsItemHovered();
  if (ImGui::IsItemClicked() && visible_clicked) {
    *visible_clicked = true;
  }

  // Draw eye icon using SVG texture
  {
    void* eye_tex = visible ? eye_texture : eye_off_texture;
    if (eye_tex != nullptr && icon_button_size > 0.0f) {
      const ImVec2 eye_img_min(eye_min.x, eye_min.y);
      const ImVec2 eye_img_max(eye_img_min.x + icon_button_size, eye_img_min.y + icon_button_size);

      ImU32 tint_col;
      if (eye_hovered) {
        tint_col = IM_COL32(255, 255, 255, 255);
      } else if (visible) {
        tint_col = (selected || hovered)
            ? IM_COL32(200, 210, 220, 240)
            : IM_COL32(140, 150, 165, 180);
      } else {
        tint_col = IM_COL32(100, 105, 115, 120);
      }

      draw_list->AddImage(reinterpret_cast<ImTextureID>(eye_tex), eye_img_min, eye_img_max,
                          ImVec2(0, 0), ImVec2(1, 1), tint_col);
    }
  }

  // ── Inline rename input ─────────────────────────────────────────────────
  if (rename_buffer != nullptr && rename_buffer_size > 0) {
    const ImVec2 input_pos(x_offset, item_min.y + 1.0f);
    const float input_width = (std::max)(max_text_x - x_offset - 2.0f, 60.0f);
    ImGui::SetCursorScreenPos(input_pos);
    ImGui::SetNextItemWidth(input_width);
    if (request_rename_focus) ImGui::SetKeyboardFocusHere();
    const bool submitted = ImGui::InputText("##rename", rename_buffer, rename_buffer_size,
                                            ImGuiInputTextFlags_AutoSelectAll |
                                            ImGuiInputTextFlags_EnterReturnsTrue);
    const bool deactivated = ImGui::IsItemDeactivatedAfterEdit();
    const bool finished = submitted || ImGui::IsItemDeactivated();

    uint32_t result = 0;
    if (submitted || deactivated) result |= GUAVA_IMGUI_TREE_NODE_RENAME_COMMITTED;
    if (finished) result |= GUAVA_IMGUI_TREE_NODE_RENAME_FINISHED;
    if (is_open) result |= GUAVA_IMGUI_TREE_NODE_OPEN;
    ImGui::PopID();
    return result;
  }

  // ── Click handling (content area only, excluding eye button) ────────────
  ImGui::SetNextItemAllowOverlap();
  ImGui::SetCursorScreenPos(ImVec2(content_left, item_min.y));
  ImGui::InvisibleButton("##row", ImVec2(eye_button_area_left - content_left, row_height));

  uint32_t result = 0;
  if (ImGui::IsItemClicked()) {
    result |= GUAVA_IMGUI_TREE_NODE_CLICKED;
    if (has_children) {
      is_open = !is_open;
      storage->SetInt(open_id, is_open ? 1 : 0);
    }
  }
  if (is_open) result |= GUAVA_IMGUI_TREE_NODE_OPEN;

  ImGui::PopID();
  return result;
}

extern "C" uint32_t guava_imgui_draw_view_cube(const float view[16], float x,
                                               float y, float size,
                                               float out_drag_delta[2]) {
  if (out_drag_delta != nullptr) {
    out_drag_delta[0] = 0.0f;
    out_drag_delta[1] = 0.0f;
  }
  if (!g_imgui_initialized || view == nullptr || size <= 0.0f) {
    return GUAVA_IMGUI_VIEW_CUBE_NONE;
  }

  const ImVec2 cube_pos(x, y);
  const ImVec2 cube_size(size, size);
  const ImVec2 center(x + size * 0.5f, y + size * 0.5f);
  const float radius = size * 1.38f;
  const float plate_radius = size * 0.47f;
  const float positive_axis_radius = size * 0.078f;
  const float negative_axis_radius = size * 0.056f;

  static const ViewCubePoint3 cube_vertices[8] = {
      {-1.0f, -1.0f, -1.0f}, {1.0f, -1.0f, -1.0f}, {1.0f, 1.0f, -1.0f},
      {-1.0f, 1.0f, -1.0f},  {-1.0f, -1.0f, 1.0f}, {1.0f, -1.0f, 1.0f},
      {1.0f, 1.0f, 1.0f},    {-1.0f, 1.0f, 1.0f},
  };
  static const ViewCubeFaceInfo faces[6] = {
      {GUAVA_IMGUI_VIEW_CUBE_FRONT,
       "Front",
       {0.0f, 0.0f, 1.0f},
       {4, 5, 6, 7},
       IM_COL32(128, 140, 158, 236)},
      {GUAVA_IMGUI_VIEW_CUBE_BACK,
       "Back",
       {0.0f, 0.0f, -1.0f},
       {1, 0, 3, 2},
       IM_COL32(92, 99, 112, 226)},
      {GUAVA_IMGUI_VIEW_CUBE_LEFT,
       "Left",
       {-1.0f, 0.0f, 0.0f},
       {0, 4, 7, 3},
       IM_COL32(120, 112, 114, 232)},
      {GUAVA_IMGUI_VIEW_CUBE_RIGHT,
       "Right",
       {1.0f, 0.0f, 0.0f},
       {5, 1, 2, 6},
       IM_COL32(140, 120, 114, 236)},
      {GUAVA_IMGUI_VIEW_CUBE_TOP,
       "Top",
       {0.0f, 1.0f, 0.0f},
       {7, 6, 2, 3},
       IM_COL32(120, 132, 120, 236)},
      {GUAVA_IMGUI_VIEW_CUBE_BOTTOM,
       "Bottom",
       {0.0f, -1.0f, 0.0f},
       {0, 1, 5, 4},
       IM_COL32(96, 102, 96, 226)},
  };
  static const ViewCubeAxisInfo axes[6] = {
      {GUAVA_IMGUI_VIEW_CUBE_RIGHT,
       "X",
       {1.0f, 0.0f, 0.0f},
       IM_COL32(224, 94, 84, 255),
       true},
      {GUAVA_IMGUI_VIEW_CUBE_LEFT,
       "-X",
       {-1.0f, 0.0f, 0.0f},
       IM_COL32(224, 94, 84, 255),
       false},
      {GUAVA_IMGUI_VIEW_CUBE_TOP,
       "Y",
       {0.0f, 1.0f, 0.0f},
       IM_COL32(100, 192, 94, 255),
       true},
      {GUAVA_IMGUI_VIEW_CUBE_BOTTOM,
       "-Y",
       {0.0f, -1.0f, 0.0f},
       IM_COL32(100, 192, 94, 255),
       false},
      {GUAVA_IMGUI_VIEW_CUBE_FRONT,
       "Z",
       {0.0f, 0.0f, 1.0f},
       IM_COL32(86, 146, 228, 255),
       true},
      {GUAVA_IMGUI_VIEW_CUBE_BACK,
       "-Z",
       {0.0f, 0.0f, -1.0f},
       IM_COL32(86, 146, 228, 255),
       false},
  };

  ViewCubePoint3 rotated_vertices[8];
  ViewCubePoint2 projected_vertices[8];
  for (int index = 0; index < 8; ++index) {
    rotated_vertices[index] = rotate_by_view(view, cube_vertices[index]);
    projected_vertices[index] =
        project_view_cube_point(rotated_vertices[index], center, radius);
  }

  ViewCubeAxisHandle axis_handles[6];
  for (int index = 0; index < 6; ++index) {
    const ViewCubePoint3 rotated_axis =
        rotate_by_view(view, scale_point3(axes[index].direction, 1.58f));
    const ViewCubePoint2 projected_axis =
        project_view_cube_point(rotated_axis, center, radius);
    axis_handles[index] = {
        axes[index].id,
        axes[index].label,
        axes[index].color,
        axes[index].positive,
        to_imvec2(projected_axis),
        axes[index].positive ? positive_axis_radius : negative_axis_radius,
        rotated_axis.z,
    };
  }

  ImGui::PushID("guava_editor_view_cube");
  ImGui::SetCursorScreenPos(cube_pos);
  ImGui::InvisibleButton("##view_cube", cube_size,
                         ImGuiButtonFlags_MouseButtonLeft);
  const bool hovered =
      ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem);
  const bool active = ImGui::IsItemActive();
  const bool dragging =
      active && ImGui::IsMouseDragging(ImGuiMouseButton_Left, 2.5f);
  const ImGuiID item_id = ImGui::GetItemID();
  const ImGuiID pressed_target_key = item_id ^ 0x51a13d7u;
  const ImGuiID dragged_key = item_id ^ 0x2c8f48b1u;
  ImGuiStorage* storage = ImGui::GetStateStorage();
  const ImVec2 mouse = ImGui::GetIO().MousePos;
  ImDrawList* draw_list = ImGui::GetWindowDrawList();

  int axis_hit_order[6] = {0, 1, 2, 3, 4, 5};
  std::sort(axis_hit_order, axis_hit_order + 6, [&](int lhs, int rhs) {
    const bool lhs_front = axis_handles[lhs].depth >= 0.0f;
    const bool rhs_front = axis_handles[rhs].depth >= 0.0f;
    if (lhs_front != rhs_front) {
      return lhs_front > rhs_front;
    }
    if (axis_handles[lhs].depth != axis_handles[rhs].depth) {
      return axis_handles[lhs].depth > axis_handles[rhs].depth;
    }
    return axis_handles[lhs].positive > axis_handles[rhs].positive;
  });

  uint32_t hovered_face = GUAVA_IMGUI_VIEW_CUBE_NONE;
  if (hovered) {
    for (int order_index = 0; order_index < 6; ++order_index) {
      const ViewCubeAxisHandle& handle =
          axis_handles[axis_hit_order[order_index]];
      if (distance_squared(handle.center, mouse) <=
          handle.radius * handle.radius) {
        hovered_face = handle.id;
        break;
      }
    }
  }

  if (ImGui::IsItemActivated()) {
    storage->SetInt(pressed_target_key, static_cast<int>(hovered_face));
    storage->SetBool(dragged_key, false);
  }
  const uint32_t pressed_target =
      static_cast<uint32_t>(storage->GetInt(pressed_target_key, 0));
  if (dragging) {
    storage->SetBool(dragged_key, true);
    if (out_drag_delta != nullptr) {
      out_drag_delta[0] = ImGui::GetIO().MouseDelta.x;
      out_drag_delta[1] = ImGui::GetIO().MouseDelta.y;
    }
  }

  draw_list->AddCircleFilled(ImVec2(center.x, center.y + size * 0.026f),
                             plate_radius, IM_COL32(0, 0, 0, hovered ? 54 : 34),
                             48);
  draw_list->AddCircleFilled(center, plate_radius,
                             IM_COL32(20, 24, 30, hovered ? 214 : 184), 48);
  draw_list->AddCircle(center, plate_radius,
                       IM_COL32(122, 134, 150, hovered ? 132 : 92), 48, 1.2f);
  draw_list->AddCircle(center, plate_radius * 0.82f,
                       IM_COL32(255, 255, 255, 18), 48, 1.0f);

  for (int index = 0; index < 6; ++index) {
    const ViewCubeAxisHandle& handle = axis_handles[index];
    if (handle.depth >= 0.0f) {
      continue;
    }
    const bool axis_hovered = hovered_face == handle.id;
    draw_list->AddLine(center, handle.center,
                       scale_color(handle.color, axis_hovered ? 0.72f : 0.54f),
                       axis_hovered ? 2.4f : 1.8f);
    draw_list->AddCircleFilled(
        handle.center, handle.radius,
        IM_COL32(204, 210, 220, axis_hovered ? 210 : 168), 20);
    draw_list->AddCircle(
        handle.center, handle.radius,
        scale_color(handle.color, axis_hovered ? 1.12f : 0.84f), 20,
        axis_hovered ? 1.5f : 1.1f);
  }

  for (int index = 0; index < 6; ++index) {
    const ViewCubeAxisHandle& handle = axis_handles[index];
    if (handle.depth < 0.0f) {
      continue;
    }
    const bool axis_hovered = hovered_face == handle.id;
    const float line_thickness = handle.positive ? (axis_hovered ? 3.2f : 2.6f)
                                                 : (axis_hovered ? 2.4f : 1.8f);
    draw_list->AddLine(center, handle.center,
                       scale_color(handle.color, axis_hovered ? 1.08f : 0.82f),
                       line_thickness);

    if (handle.positive) {
      draw_list->AddCircleFilled(handle.center, handle.radius, handle.color,
                                 24);
      draw_list->AddCircle(handle.center, handle.radius,
                           IM_COL32(246, 248, 252, axis_hovered ? 244 : 182),
                           24, axis_hovered ? 1.8f : 1.2f);
      const float text_size = std::clamp(size * 0.11f, 10.0f, 12.5f);
      ImFont* font = ImGui::GetFont();
      const ImVec2 label_size =
          font->CalcTextSizeA(text_size, FLT_MAX, 0.0f, handle.label);

      draw_list->AddText(font, text_size,
                         ImVec2(handle.center.x - label_size.x * 0.5f,
                                handle.center.y - label_size.y * 0.5f),
                         IM_COL32(248, 250, 253, 248), handle.label);
    } else {
      draw_list->AddCircleFilled(
          handle.center, handle.radius,
          IM_COL32(208, 214, 224, axis_hovered ? 220 : 184), 20);
      draw_list->AddCircle(
          handle.center, handle.radius,
          scale_color(handle.color, axis_hovered ? 1.08f : 0.82f), 20,
          axis_hovered ? 1.6f : 1.1f);
    }
  }

  draw_list->AddCircleFilled(center, size * 0.03f,
                             IM_COL32(234, 238, 244, hovered ? 228 : 196), 18);

  uint32_t result = GUAVA_IMGUI_VIEW_CUBE_NONE;
  if (hovered_face != GUAVA_IMGUI_VIEW_CUBE_NONE) {
    result |= GUAVA_IMGUI_VIEW_CUBE_HOVERED;
  }
  if (active) {
    result |= GUAVA_IMGUI_VIEW_CUBE_ACTIVE;
  }
  if (dragging) {
    result |= GUAVA_IMGUI_VIEW_CUBE_DRAGGING;
  }

  if (ImGui::IsItemDeactivated()) {
    const bool was_dragged = storage->GetBool(dragged_key, false);
    if (!was_dragged && pressed_target != GUAVA_IMGUI_VIEW_CUBE_NONE &&
        hovered_face == pressed_target) {
      result = (result & ~0xffu) | pressed_target;
    }
    storage->SetInt(pressed_target_key, 0);
    storage->SetBool(dragged_key, false);
  }

  ImGui::PopID();
  return result;
}
