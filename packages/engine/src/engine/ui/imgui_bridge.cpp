#include "imgui_bridge.h"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <initializer_list>
#include <string>

#include "backends/imgui_impl_sdl3.h"
#include "imgui.h"
#include "imgui_internal.h"

extern "C" bool guava_imgui_metal_backend_init(void* metal_bridge_ctx);
extern "C" void guava_imgui_metal_backend_shutdown(void);
extern "C" bool guava_imgui_vulkan_backend_init(void* vk_bridge_ctx);
extern "C" void guava_imgui_vulkan_backend_shutdown(void);

static bool g_using_vulkan_backend = false;

namespace {

std::string make_string(const char* text, size_t text_len) {
  return std::string(text, text_len);
}

ImGuiWindowFlags to_imgui_window_flags(uint32_t flags) {
  ImGuiWindowFlags result = ImGuiWindowFlags_None;
  if ((flags & GUAVA_IMGUI_WINDOW_NO_TITLE_BAR) != 0)
    result |= ImGuiWindowFlags_NoTitleBar;
  if ((flags & GUAVA_IMGUI_WINDOW_NO_RESIZE) != 0)
    result |= ImGuiWindowFlags_NoResize;
  if ((flags & GUAVA_IMGUI_WINDOW_NO_MOVE) != 0)
    result |= ImGuiWindowFlags_NoMove;
  if ((flags & GUAVA_IMGUI_WINDOW_NO_SCROLLBAR) != 0)
    result |= ImGuiWindowFlags_NoScrollbar;
  if ((flags & GUAVA_IMGUI_WINDOW_NO_SAVED_SETTINGS) != 0)
    result |= ImGuiWindowFlags_NoSavedSettings;
  if ((flags & GUAVA_IMGUI_WINDOW_NO_DOCKING) != 0)
    result |= ImGuiWindowFlags_NoDocking;
  if ((flags & GUAVA_IMGUI_WINDOW_NO_COLLAPSE) != 0)
    result |= ImGuiWindowFlags_NoCollapse;
  if ((flags & GUAVA_IMGUI_WINDOW_NO_BACKGROUND) != 0)
    result |= ImGuiWindowFlags_NoBackground;
  if ((flags & GUAVA_IMGUI_WINDOW_NO_DECORATION) != 0)
    result |= ImGuiWindowFlags_NoDecoration;
  if ((flags & GUAVA_IMGUI_WINDOW_ALWAYS_AUTO_RESIZE) != 0)
    result |= ImGuiWindowFlags_AlwaysAutoResize;
  if ((flags & GUAVA_IMGUI_WINDOW_NO_SCROLL_WITH_MOUSE) != 0)
    result |= ImGuiWindowFlags_NoScrollWithMouse;
  return result;
}

ImGuiCol to_imgui_style_color(uint32_t slot) {
  switch (slot) {
    case GUAVA_IMGUI_STYLE_COLOR_TEXT:
      return ImGuiCol_Text;
    case GUAVA_IMGUI_STYLE_COLOR_BUTTON:
      return ImGuiCol_Button;
    case GUAVA_IMGUI_STYLE_COLOR_BUTTON_HOVERED:
      return ImGuiCol_ButtonHovered;
    case GUAVA_IMGUI_STYLE_COLOR_BUTTON_ACTIVE:
      return ImGuiCol_ButtonActive;
    case GUAVA_IMGUI_STYLE_COLOR_FRAME_BG:
      return ImGuiCol_FrameBg;
    case GUAVA_IMGUI_STYLE_COLOR_FRAME_BG_HOVERED:
      return ImGuiCol_FrameBgHovered;
    case GUAVA_IMGUI_STYLE_COLOR_FRAME_BG_ACTIVE:
      return ImGuiCol_FrameBgActive;
    case GUAVA_IMGUI_STYLE_COLOR_BORDER:
      return ImGuiCol_Border;
    case GUAVA_IMGUI_STYLE_COLOR_TEXT_SELECTED_BG:
      return ImGuiCol_TextSelectedBg;
    case GUAVA_IMGUI_STYLE_COLOR_NAV_CURSOR:
      return ImGuiCol_NavCursor;
    case GUAVA_IMGUI_STYLE_COLOR_INPUT_TEXT_CURSOR:
      return ImGuiCol_InputTextCursor;
    default:
      return ImGuiCol_Text;
  }
}

ImGuiStyleVar to_imgui_style_var(uint32_t slot) {
  switch (slot) {
    case GUAVA_IMGUI_STYLE_VAR_ALPHA:
      return ImGuiStyleVar_Alpha;
    case GUAVA_IMGUI_STYLE_VAR_FRAME_PADDING:
      return ImGuiStyleVar_FramePadding;
    case GUAVA_IMGUI_STYLE_VAR_ITEM_SPACING:
      return ImGuiStyleVar_ItemSpacing;
    case GUAVA_IMGUI_STYLE_VAR_FRAME_ROUNDING:
      return ImGuiStyleVar_FrameRounding;
    case GUAVA_IMGUI_STYLE_VAR_WINDOW_MIN_SIZE:
      return ImGuiStyleVar_WindowMinSize;
    case GUAVA_IMGUI_STYLE_VAR_WINDOW_PADDING:
      return ImGuiStyleVar_WindowPadding;
    default:
      return ImGuiStyleVar_Alpha;
  }
}

std::string first_existing_path(std::initializer_list<const char*> candidates) {
  for (const char* candidate : candidates) {
    if (candidate == nullptr || candidate[0] == '\0') {
      continue;
    }
    std::error_code ec;
    if (std::filesystem::exists(candidate, ec)) {
      return std::string(candidate);
    }
  }
  return {};
}

std::string find_ui_font_path() {
#if defined(__APPLE__)
  return first_existing_path({
      "/System/Library/Fonts/SFNS.ttf",
      "/System/Library/Fonts/Helvetica.ttc",
      "/System/Library/Fonts/Supplemental/Arial.ttf",
  });
#elif defined(_WIN32)
  return first_existing_path({
      "C:/Windows/Fonts/segoeui.ttf",
      "C:/Windows/Fonts/arial.ttf",
  });
#else
  return first_existing_path({
      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
      "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
      "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
  });
#endif
}

std::string find_bundled_ui_font_path() {
  return first_existing_path({
      "assets/ui/fonts/Inter-Regular.ttf",
      "assets/ui/fonts/Inter-Medium.ttf",
  });
}

std::string find_cjk_font_path() {
#if defined(__APPLE__)
  return first_existing_path({
      "/System/Library/Fonts/PingFang.ttc",
      "/System/Library/Fonts/Hiragino Sans GB.ttc",
      "/System/Library/Fonts/STHeiti Light.ttc",
      "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
      "/Library/Fonts/Arial Unicode.ttf",
  });
#elif defined(_WIN32)
  return first_existing_path({
      "C:/Windows/Fonts/msyh.ttc",
      "C:/Windows/Fonts/msyh.ttf",
      "C:/Windows/Fonts/simhei.ttf",
      "C:/Windows/Fonts/simsun.ttc",
  });
#else
  return first_existing_path({
      "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
      "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
      "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf",
      "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
  });
#endif
}

std::string find_bundled_cjk_font_path() {
  return first_existing_path({
      "assets/ui/fonts/NotoSansSC-Regular.otf",
      "assets/ui/fonts/NotoSansSC-Regular.ttf",
      "assets/ui/fonts/NotoSansCJKsc-Regular.otf",
  });
}

ImVec4 make_color(int r, int g, int b, int a = 255) {
  constexpr float inv_255 = 1.0f / 255.0f;
  return ImVec4(
      static_cast<float>(r) * inv_255, static_cast<float>(g) * inv_255,
      static_cast<float>(b) * inv_255, static_cast<float>(a) * inv_255);
}

}  // namespace

bool g_imgui_initialized = false;
ImDrawData* g_draw_data = nullptr;
std::string g_ini_path;
ImGuiID g_dockspace_id = 0;

void build_default_dock_layout() {
  ImGuiViewport* viewport = ImGui::GetMainViewport();
  if (viewport == nullptr) {
    return;
  }

  g_dockspace_id = ImGui::GetID("GuavaEditorDockspace");
  ImGui::DockBuilderRemoveNode(g_dockspace_id);
  ImGui::DockBuilderAddNode(
      g_dockspace_id,
      ImGuiDockNodeFlags_DockSpace | ImGuiDockNodeFlags_PassthruCentralNode);
  ImGui::DockBuilderSetNodeSize(g_dockspace_id, viewport->Size);

  ImGuiID dock_main = g_dockspace_id;

  // 1) Left sidebar: Scene hierarchy + Place Actors — 20% width.
  ImGuiID dock_left = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Left,
                                                  0.20f, nullptr, &dock_main);

  // 3) Right sidebar: Inspector (top 60%) + Jarvis Terminal (bottom 40%) — 26%
  // width.
  ImGuiID dock_right = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Right,
                                                   0.26f, nullptr, &dock_main);

  // 4) Center: 3D Viewport fills the rest.
  ImGuiID dock_viewport = dock_main;

  // Left sidebar: Scene hierarchy tab (with Place Actors) + Project stacked.
  ImGuiID dock_left_bottom;
  ImGuiID dock_scene = ImGui::DockBuilderSplitNode(
      dock_left, ImGuiDir_Up, 0.60f, nullptr, &dock_left_bottom);
  ImGuiID dock_project = dock_left_bottom;

  // Right sidebar: inspector top, Jarvis bottom.
  ImGuiID dock_right_bottom;
  ImGuiID dock_inspector = ImGui::DockBuilderSplitNode(
      dock_right, ImGuiDir_Up, 0.58f, nullptr, &dock_right_bottom);
  ImGuiID dock_jarvis = dock_right_bottom;

  // Left sidebar.
  ImGui::DockBuilderDockWindow("Scene###scene_panel", dock_scene);
  ImGui::DockBuilderDockWindow("Project###project_panel", dock_project);

  // Right sidebar.
  ImGui::DockBuilderDockWindow("Details###details_panel", dock_inspector);
  ImGui::DockBuilderDockWindow("Jarvis Terminal##ai_chat_panel", dock_jarvis);

  // Center.
  ImGui::DockBuilderDockWindow("Viewport###viewport_panel", dock_viewport);
  ImGui::DockBuilderFinish(g_dockspace_id);
}

void build_animation_dock_layout() {
  ImGuiViewport* viewport = ImGui::GetMainViewport();
  if (viewport == nullptr) {
    return;
  }

  g_dockspace_id = ImGui::GetID("GuavaEditorDockspace");
  ImGui::DockBuilderRemoveNode(g_dockspace_id);
  ImGui::DockBuilderAddNode(
      g_dockspace_id,
      ImGuiDockNodeFlags_DockSpace | ImGuiDockNodeFlags_PassthruCentralNode);
  ImGui::DockBuilderSetNodeSize(g_dockspace_id, viewport->Size);

  ImGuiID dock_main = g_dockspace_id;

  ImGuiID dock_timeline = ImGui::DockBuilderSplitNode(
      dock_main, ImGuiDir_Down, 0.18f, nullptr, &dock_main);
  ImGuiID dock_left = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Left,
                                                  0.20f, nullptr, &dock_main);
  ImGuiID dock_right = ImGui::DockBuilderSplitNode(dock_main, ImGuiDir_Right,
                                                   0.26f, nullptr, &dock_main);
  ImGuiID dock_viewport = dock_main;

  ImGuiID dock_left_bottom;
  ImGuiID dock_scene = ImGui::DockBuilderSplitNode(
      dock_left, ImGuiDir_Up, 0.52f, nullptr, &dock_left_bottom);
  ImGuiID dock_assets = dock_left_bottom;

  ImGuiID dock_right_bottom;
  ImGuiID dock_inspector = ImGui::DockBuilderSplitNode(
      dock_right, ImGuiDir_Up, 0.58f, nullptr, &dock_right_bottom);
  ImGuiID dock_jarvis = dock_right_bottom;

  ImGui::DockBuilderDockWindow("Command Timeline##command_timeline_panel",
                               dock_timeline);
  ImGui::DockBuilderDockWindow("Animation Editor###animation_editor_panel",
                               dock_timeline);

  ImGui::DockBuilderDockWindow("Scene###scene_panel", dock_scene);
  ImGui::DockBuilderDockWindow("Project###project_panel", dock_scene);

  ImGui::DockBuilderDockWindow("Content Browser###content_browser_panel",
                               dock_assets);
  ImGui::DockBuilderDockWindow("AI Utilities###editor_utilities_panel",
                               dock_assets);

  ImGui::DockBuilderDockWindow("Details###details_panel", dock_inspector);
  ImGui::DockBuilderDockWindow("Jarvis Terminal##ai_chat_panel", dock_jarvis);

  ImGui::DockBuilderDockWindow("Viewport###viewport_panel", dock_viewport);
  ImGui::DockBuilderFinish(g_dockspace_id);
}

void apply_guava_editor_style(float content_scale) {
  ImGuiStyle& style = ImGui::GetStyle();
  style = ImGuiStyle();

  style.WindowPadding = ImVec2(10.0f, 10.0f);
  style.FramePadding = ImVec2(8.0f, 6.0f);
  style.CellPadding = ImVec2(8.0f, 6.0f);
  style.ItemSpacing = ImVec2(8.0f, 6.0f);
  style.ItemInnerSpacing = ImVec2(6.0f, 4.0f);
  style.TouchExtraPadding = ImVec2(0.0f, 0.0f);
  style.IndentSpacing = 20.0f;
  style.ScrollbarSize = 12.0f;
  style.GrabMinSize = 12.0f;

  style.WindowBorderSize = 0.0f;
  style.ChildBorderSize = 1.0f;
  style.PopupBorderSize = 1.0f;
  style.FrameBorderSize = 0.0f;
  style.TabBorderSize = 0.0f;

  style.WindowRounding = 6.0f;
  style.ChildRounding = 6.0f;
  style.FrameRounding = 5.0f;
  style.PopupRounding = 6.0f;
  style.ScrollbarRounding = 8.0f;
  style.GrabRounding = 4.0f;
  style.TabRounding = 5.0f;

  style.WindowTitleAlign = ImVec2(0.03f, 0.5f);
  style.WindowMenuButtonPosition = ImGuiDir_None;
  style.ColorButtonPosition = ImGuiDir_Right;
  style.ButtonTextAlign = ImVec2(0.5f, 0.5f);
  style.SelectableTextAlign = ImVec2(0.0f, 0.5f);
  style.WindowMinSize = ImVec2(220.0f, 120.0f);

  ImVec4* colors = style.Colors;
  colors[ImGuiCol_Text] = make_color(225, 230, 240);
  colors[ImGuiCol_TextDisabled] = make_color(140, 150, 165);
  colors[ImGuiCol_WindowBg] = make_color(41, 41, 41);  // Scene panel background
  colors[ImGuiCol_ChildBg] = make_color(41, 41, 41);  // Match window bg
  colors[ImGuiCol_PopupBg] = make_color(32, 34, 40, 245);
  colors[ImGuiCol_Border] = make_color(58, 64, 75, 120);
  colors[ImGuiCol_BorderShadow] = make_color(0, 0, 0, 0);

  colors[ImGuiCol_FrameBg] = make_color(30, 32, 36);
  colors[ImGuiCol_FrameBgHovered] = make_color(40, 55, 48);
  colors[ImGuiCol_FrameBgActive] = make_color(30, 65, 48);
  colors[ImGuiCol_TitleBg] = make_color(22, 23, 26);
  colors[ImGuiCol_TitleBgActive] = make_color(30, 32, 36);
  colors[ImGuiCol_TitleBgCollapsed] = make_color(20, 21, 23, 180);
  colors[ImGuiCol_MenuBarBg] = make_color(28, 30, 34);
  colors[ImGuiCol_ScrollbarBg] = make_color(20, 21, 24, 120);
  colors[ImGuiCol_ScrollbarGrab] = make_color(70, 75, 85, 160);
  colors[ImGuiCol_ScrollbarGrabHovered] = make_color(90, 100, 115, 180);
  colors[ImGuiCol_ScrollbarGrabActive] = make_color(110, 120, 140, 200);

  // Primary accent for human-authored interactions.
  const ImVec4 accent_green =
      make_color(34, 205, 100);  // Slightly more vibrant
  const ImVec4 accent_green_hover =
      make_color(50, 225, 120);  // +10% brightness
  const ImVec4 accent_green_dim = make_color(34, 205, 100, 80);  // 30% opacity

  // Secondary accent for AI-origin interactions.
  const ImVec4 accent_ai = make_color(144, 96, 232);
  const ImVec4 accent_ai_hover = make_color(170, 120, 245);
  const ImVec4 accent_ai_dim = make_color(144, 96, 232, 90);

  colors[ImGuiCol_CheckMark] = accent_green;
  colors[ImGuiCol_SliderGrab] = accent_green;
  colors[ImGuiCol_SliderGrabActive] = accent_green_hover;

  // Selected state for Scene Hierarchy and Content Browser
  colors[ImGuiCol_Header] = accent_green_dim;
  colors[ImGuiCol_HeaderHovered] = make_color(34, 205, 100, 120);
  colors[ImGuiCol_HeaderActive] = make_color(34, 205, 100, 160);

  // Tab colors
  colors[ImGuiCol_TabHovered] = accent_green_hover;
  colors[ImGuiCol_TabActive] = accent_green;
  colors[ImGuiCol_TabUnfocusedActive] = accent_green_dim;

  colors[ImGuiCol_Button] = make_color(45, 48, 54);
  colors[ImGuiCol_ButtonHovered] = make_color(60, 65, 72);
  colors[ImGuiCol_ButtonActive] = accent_green;
  colors[ImGuiCol_Separator] = make_color(54, 60, 69, 140);
  colors[ImGuiCol_SeparatorHovered] = accent_green_hover;
  colors[ImGuiCol_SeparatorActive] = accent_green;
  colors[ImGuiCol_ResizeGrip] = make_color(85, 95, 110, 60);
  colors[ImGuiCol_ResizeGripHovered] = accent_green_hover;
  colors[ImGuiCol_ResizeGripActive] = accent_green;
  colors[ImGuiCol_InputTextCursor] = make_color(42, 236, 136);
  colors[ImGuiCol_Tab] = make_color(36, 39, 44);
  colors[ImGuiCol_TabUnfocused] = make_color(30, 33, 37);
  colors[ImGuiCol_DockingPreview] = accent_green_dim;
  colors[ImGuiCol_DockingEmptyBg] = make_color(20, 22, 26);
  colors[ImGuiCol_PlotLines] = accent_green;
  colors[ImGuiCol_PlotLinesHovered] = accent_green_hover;
  colors[ImGuiCol_PlotHistogram] = accent_ai;
  colors[ImGuiCol_PlotHistogramHovered] = accent_ai_hover;
  colors[ImGuiCol_TableHeaderBg] = make_color(42, 46, 52);
  colors[ImGuiCol_TableBorderStrong] = make_color(60, 65, 75);
  colors[ImGuiCol_TableBorderLight] = make_color(45, 49, 56);
  colors[ImGuiCol_TableRowBg] = make_color(0, 0, 0, 0);
  colors[ImGuiCol_TableRowBgAlt] = make_color(255, 255, 255, 8);
  colors[ImGuiCol_TextSelectedBg] = make_color(34, 205, 100, 100);
  colors[ImGuiCol_DragDropTarget] = accent_green_hover;
  colors[ImGuiCol_NavCursor] = accent_green;
  colors[ImGuiCol_NavWindowingHighlight] = make_color(255, 255, 255, 60);
  colors[ImGuiCol_NavWindowingDimBg] = make_color(0, 0, 0, 100);
  colors[ImGuiCol_ModalWindowDimBg] = make_color(0, 0, 0, 120);

  const float scale = content_scale > 0.0f ? content_scale : 1.0f;
  style.ScaleAllSizes(scale);
  style.FontScaleDpi = 1.0f;
}

void configure_fonts(float content_scale) {
  ImGuiIO& io = ImGui::GetIO();
  io.ConfigDpiScaleFonts = false;
  io.Fonts->Clear();
  io.Fonts->Flags |= ImFontAtlasFlags_NoPowerOfTwoHeight;

  const float scale = content_scale > 0.0f ? content_scale : 1.0f;
  const float font_size = 15.0f * scale;  // 从 16px 降至 15px，提升紧凑感

  ImFontConfig base_cfg = {};
  base_cfg.OversampleH = 3;  // 提升采样质量
  base_cfg.OversampleV = 1;
  base_cfg.RasterizerMultiply = 1.0f;  // 移除 1.1x 的人工加粗，使中文字体更清爽
  base_cfg.FontNo = 0;

  const std::string bundled_ui_font_path = find_bundled_ui_font_path();
  const std::string bundled_cjk_font_path = find_bundled_cjk_font_path();
  const std::string ui_font_path = !bundled_ui_font_path.empty()
                                       ? bundled_ui_font_path
                                       : find_ui_font_path();
  const std::string cjk_font_path = !bundled_cjk_font_path.empty()
                                        ? bundled_cjk_font_path
                                        : find_cjk_font_path();

  ImFont* primary_font = nullptr;
  bool primary_uses_ui_font = false;
  if (!ui_font_path.empty()) {
    primary_font =
        io.Fonts->AddFontFromFileTTF(ui_font_path.c_str(), font_size, &base_cfg,
                                     io.Fonts->GetGlyphRangesDefault());
    primary_uses_ui_font = primary_font != nullptr;
  }
  if (primary_font == nullptr && !cjk_font_path.empty()) {
    primary_font = io.Fonts->AddFontFromFileTTF(
        cjk_font_path.c_str(), font_size, &base_cfg,
        io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
  }
  if (primary_font == nullptr) {
    primary_font = io.Fonts->AddFontDefault();
  }

  if (primary_uses_ui_font && !cjk_font_path.empty()) {
    ImFontConfig merge_cfg = base_cfg;
    merge_cfg.MergeMode = true;
    merge_cfg.FontNo = 0;
    merge_cfg.GlyphMinAdvanceX = font_size * 0.5f;
    io.Fonts->AddFontFromFileTTF(
        cjk_font_path.c_str(), font_size, &merge_cfg,
        io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
  }

  io.FontDefault = primary_font;
}

extern "C" bool guava_imgui_init(SDL_Window* window, void* metal_bridge_ctx,
                                 uint32_t color_target_format) {
  (void)color_target_format;
  if (g_imgui_initialized) {
    return true;
  }

  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGuiIO& io = ImGui::GetIO();
  io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
  io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
  io.ConfigDockingAlwaysTabBar = true;
  io.ConfigInputTextCursorBlink = true;
  io.ConfigWindowsMoveFromTitleBarOnly = true;

  if (char* pref_path = SDL_GetPrefPath("Guava", "Editor")) {
    g_ini_path = std::string(pref_path) + "imgui.ini";
    io.IniFilename = g_ini_path.c_str();
    SDL_free(pref_path);
  } else {
    g_ini_path.clear();
    io.IniFilename = nullptr;
  }

  const float reported_scale =
      SDL_GetDisplayContentScale(SDL_GetPrimaryDisplay());
  const float main_scale = reported_scale > 0.0f ? reported_scale : 1.0f;
  configure_fonts(main_scale);

  apply_guava_editor_style(main_scale);

  if (!ImGui_ImplSDL3_InitForMetal(window)) {
    ImGui::DestroyContext();
    return false;
  }

  if (!guava_imgui_metal_backend_init(metal_bridge_ctx)) {
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();
    return false;
  }

  g_imgui_initialized = true;
  return true;
}

extern "C" bool guava_imgui_init_vulkan(SDL_Window* window,
                                        void* vk_bridge_ctx) {
  if (g_imgui_initialized) {
    return true;
  }

  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGuiIO& io = ImGui::GetIO();
  io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
  io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
  io.ConfigDockingAlwaysTabBar = true;
  io.ConfigInputTextCursorBlink = true;
  io.ConfigWindowsMoveFromTitleBarOnly = true;

  if (char* pref_path = SDL_GetPrefPath("Guava", "Editor")) {
    g_ini_path = std::string(pref_path) + "imgui.ini";
    io.IniFilename = g_ini_path.c_str();
    SDL_free(pref_path);
  } else {
    g_ini_path.clear();
    io.IniFilename = nullptr;
  }

  const float reported_scale =
      SDL_GetDisplayContentScale(SDL_GetPrimaryDisplay());
  const float main_scale = reported_scale > 0.0f ? reported_scale : 1.0f;
  configure_fonts(main_scale);

  apply_guava_editor_style(main_scale);

  if (!ImGui_ImplSDL3_InitForVulkan(window)) {
    ImGui::DestroyContext();
    return false;
  }

  if (!guava_imgui_vulkan_backend_init(vk_bridge_ctx)) {
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();
    return false;
  }

  g_using_vulkan_backend = true;
  g_imgui_initialized = true;
  return true;
}

extern "C" void guava_imgui_shutdown(void) {
  if (!g_imgui_initialized) {
    return;
  }

  if (g_using_vulkan_backend) {
    guava_imgui_vulkan_backend_shutdown();
  } else {
    guava_imgui_metal_backend_shutdown();
  }
  ImGui_ImplSDL3_Shutdown();
  ImGui::DestroyContext();
  g_draw_data = nullptr;
  g_ini_path.clear();
  g_imgui_initialized = false;
  g_using_vulkan_backend = false;
}

extern "C" void guava_imgui_process_event(const SDL_Event* event) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui_ImplSDL3_ProcessEvent(event);
}

extern "C" void guava_imgui_new_frame(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui_ImplSDL3_NewFrame();
  ImGui::NewFrame();
}

extern "C" void guava_imgui_begin_dockspace(void) {
  if (!g_imgui_initialized) {
    return;
  }
  g_dockspace_id = ImGui::GetID("GuavaEditorDockspace");
  // PassthruCentralNode: 3D viewport shows through the dockspace background.
  // NoDockingOverCentralNode: prevents accidental docking over the viewport.
  ImGui::DockSpaceOverViewport(g_dockspace_id, nullptr,
                               ImGuiDockNodeFlags_PassthruCentralNode |
                                   ImGuiDockNodeFlags_NoDockingOverCentralNode);

  // Persist layout edits automatically so users can drag/resize dock panels
  // directly without opening settings or triggering explicit save actions.
  if (!g_ini_path.empty()) {
    ImGuiIO& io = ImGui::GetIO();
    if (io.WantSaveIniSettings) {
      ImGui::SaveIniSettingsToDisk(g_ini_path.c_str());
      io.WantSaveIniSettings = false;
    }
  }
}

extern "C" void guava_imgui_reset_default_layout(void) {
  if (!g_imgui_initialized) {
    return;
  }
  build_default_dock_layout();
}

extern "C" void guava_imgui_load_animation_layout(void) {
  if (!g_imgui_initialized) {
    return;
  }
  build_animation_dock_layout();
}

extern "C" void guava_imgui_save_layout(void) {
  if (!g_imgui_initialized || g_ini_path.empty()) {
    return;
  }
  ImGui::SaveIniSettingsToDisk(g_ini_path.c_str());
}

extern "C" bool guava_imgui_save_layout_to_path(const char* path,
                                                size_t path_len) {
  if (!g_imgui_initialized || path == nullptr || path_len == 0) {
    return false;
  }

  const std::string owned_path = make_string(path, path_len);
  if (owned_path.empty()) {
    return false;
  }

  std::error_code ec;
  const std::filesystem::path fs_path(owned_path);
  if (fs_path.has_parent_path()) {
    std::filesystem::create_directories(fs_path.parent_path(), ec);
  }
  ImGui::SaveIniSettingsToDisk(owned_path.c_str());
  return true;
}

extern "C" bool guava_imgui_load_layout_from_path(const char* path,
                                                  size_t path_len) {
  if (!g_imgui_initialized || path == nullptr || path_len == 0) {
    return false;
  }

  const std::string owned_path = make_string(path, path_len);
  if (owned_path.empty()) {
    return false;
  }

  std::error_code ec;
  if (!std::filesystem::exists(owned_path, ec)) {
    return false;
  }

  ImGui::LoadIniSettingsFromDisk(owned_path.c_str());
  if (!g_ini_path.empty()) {
    ImGui::SaveIniSettingsToDisk(g_ini_path.c_str());
  }
  return true;
}

extern "C" void guava_imgui_prepare(void) {
  if (!g_imgui_initialized) {
    return;
  }

  g_draw_data = nullptr;
  ImGui::Render();
  g_draw_data = ImGui::GetDrawData();
  if (g_draw_data == nullptr || g_draw_data->DisplaySize.x <= 0.0f ||
      g_draw_data->DisplaySize.y <= 0.0f) {
    return;
  }
}

extern "C" void guava_imgui_render(void) {
  if (!g_imgui_initialized || g_draw_data == nullptr ||
      g_draw_data->DisplaySize.x <= 0.0f ||
      g_draw_data->DisplaySize.y <= 0.0f) {
    return;
  }
}

extern "C" bool guava_imgui_want_capture_mouse(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::GetIO().WantCaptureMouse;
}

extern "C" bool guava_imgui_want_capture_keyboard(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::GetIO().WantCaptureKeyboard;
}

extern "C" bool guava_imgui_want_text_input(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::GetIO().WantTextInput;
}

extern "C" void guava_imgui_get_mouse_pos(float* x, float* y) {
  if (!g_imgui_initialized) {
    return;
  }
  const ImVec2 pos = ImGui::GetIO().MousePos;
  if (x) *x = pos.x;
  if (y) *y = pos.y;
}

extern "C" void guava_imgui_get_item_rect_min(float* x, float* y) {
  if (!g_imgui_initialized) {
    return;
  }
  const ImVec2 pos = ImGui::GetItemRectMin();
  if (x) *x = pos.x;
  if (y) *y = pos.y;
}

extern "C" void guava_imgui_get_item_rect_max(float* x, float* y) {
  if (!g_imgui_initialized) {
    return;
  }
  const ImVec2 pos = ImGui::GetItemRectMax();
  if (x) *x = pos.x;
  if (y) *y = pos.y;
}

extern "C" void guava_imgui_draw_list_add_line(float p1_x, float p1_y,
                                               float p2_x, float p2_y,
                                               uint32_t color,
                                               float thickness) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::GetWindowDrawList()->AddLine(ImVec2(p1_x, p1_y), ImVec2(p2_x, p2_y),
                                      color, thickness);
}

extern "C" void guava_imgui_draw_list_add_rect_filled(
    float p_min_x, float p_min_y, float p_max_x, float p_max_y, uint32_t color,
    float rounding, uint32_t flags) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::GetWindowDrawList()->AddRectFilled(
      ImVec2(p_min_x, p_min_y), ImVec2(p_max_x, p_max_y), color, rounding,
      static_cast<ImDrawFlags>(flags));
}

extern "C" void guava_imgui_draw_list_add_circle_filled(float center_x,
                                                        float center_y,
                                                        float radius,
                                                        uint32_t color,
                                                        int32_t num_segments) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::GetWindowDrawList()->AddCircleFilled(ImVec2(center_x, center_y),
                                              radius, color, num_segments);
}

extern "C" void guava_imgui_draw_list_add_text(float pos_x, float pos_y,
                                               uint32_t color, const char* text,
                                               size_t text_len) {
  if (!g_imgui_initialized || text == nullptr) {
    return;
  }
  ImGui::GetWindowDrawList()->AddText(ImVec2(pos_x, pos_y), color, text,
                                      text + text_len);
}

extern "C" void guava_imgui_draw_list_add_bezier_curve(
    float p0_x, float p0_y, float cp0_x, float cp0_y, float cp1_x,
    float cp1_y, float p1_x, float p1_y, uint32_t color, float thickness,
    int32_t num_segments) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::GetWindowDrawList()->AddBezierCubic(
      ImVec2(p0_x, p0_y), ImVec2(cp0_x, cp0_y), ImVec2(cp1_x, cp1_y),
      ImVec2(p1_x, p1_y), color, thickness, num_segments);
}

extern "C" uint32_t guava_imgui_get_color_u32(float r, float g, float b,
                                              float a) {
  if (!g_imgui_initialized) {
    return 0;
  }
  return ImGui::GetColorU32(ImVec4(r, g, b, a));
}

// 游戏内 UI 前景绘制列表 (GR-7)
extern "C" void guava_imgui_fg_draw_list_add_rect_filled(
    float p_min_x, float p_min_y, float p_max_x, float p_max_y,
    uint32_t color, float rounding) {
  if (!g_imgui_initialized) return;
  ImGui::GetForegroundDrawList()->AddRectFilled(
      ImVec2(p_min_x, p_min_y), ImVec2(p_max_x, p_max_y), color, rounding);
}

extern "C" void guava_imgui_fg_draw_list_add_text(
    float pos_x, float pos_y, uint32_t color,
    const char *text, size_t text_len) {
  if (!g_imgui_initialized) return;
  ImGui::GetForegroundDrawList()->AddText(
      ImVec2(pos_x, pos_y), color, text, text + text_len);
}

extern "C" uint32_t guava_imgui_get_color_u32_idx(uint32_t color_idx) {
  if (!g_imgui_initialized) {
    return 0;
  }
  return ImGui::GetColorU32(static_cast<ImGuiCol>(color_idx));
}

extern "C" bool guava_imgui_begin_window(const char* name, size_t name_len) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string window_name = make_string(name, name_len);
  return ImGui::Begin(window_name.c_str());
}

extern "C" bool guava_imgui_begin_window_flags(const char* name,
                                               size_t name_len,
                                               uint32_t flags) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string window_name = make_string(name, name_len);
  return ImGui::Begin(window_name.c_str(), nullptr,
                      to_imgui_window_flags(flags));
}

extern "C" bool guava_imgui_begin_window_open(const char* name, size_t name_len,
                                              bool* open) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string window_name = make_string(name, name_len);
  return ImGui::Begin(window_name.c_str(), open);
}

extern "C" bool guava_imgui_begin_window_flags_open(const char* name,
                                                    size_t name_len, bool* open,
                                                    uint32_t flags) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string window_name = make_string(name, name_len);
  return ImGui::Begin(window_name.c_str(), open, to_imgui_window_flags(flags));
}

extern "C" void guava_imgui_end_window(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::End();
}

extern "C" bool guava_imgui_begin_main_menu_bar(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::BeginMainMenuBar();
}

extern "C" void guava_imgui_end_main_menu_bar(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::EndMainMenuBar();
}

extern "C" bool guava_imgui_begin_menu(const char* label, size_t label_len) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::BeginMenu(owned_label.c_str());
}

extern "C" void guava_imgui_end_menu(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::EndMenu();
}

extern "C" void guava_imgui_open_popup(const char* id, size_t id_len) {
  if (!g_imgui_initialized) {
    return;
  }
  const std::string owned_id = make_string(id, id_len);
  ImGui::OpenPopup(owned_id.c_str());
}

extern "C" bool guava_imgui_begin_popup(const char* id, size_t id_len) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_id = make_string(id, id_len);
  return ImGui::BeginPopup(owned_id.c_str());
}

extern "C" bool guava_imgui_is_popup_open(const char* id, size_t id_len) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_id = make_string(id, id_len);
  return ImGui::IsPopupOpen(owned_id.c_str());
}

extern "C" void guava_imgui_close_current_popup(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::CloseCurrentPopup();
}

extern "C" bool guava_imgui_begin_popup_context_item(const char* id,
                                                     size_t id_len) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_id =
      id != nullptr ? make_string(id, id_len) : std::string{};
  return ImGui::BeginPopupContextItem(owned_id.empty() ? nullptr
                                                       : owned_id.c_str());
}

extern "C" bool guava_imgui_begin_popup_context_window(const char* id,
                                                       size_t id_len,
                                                       bool open_over_items) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_id =
      id != nullptr ? make_string(id, id_len) : std::string{};
  ImGuiPopupFlags flags = ImGuiPopupFlags_MouseButtonRight;
  if (!open_over_items) {
    flags |= ImGuiPopupFlags_NoOpenOverItems;
  }
  return ImGui::BeginPopupContextWindow(
      owned_id.empty() ? nullptr : owned_id.c_str(), flags);
}

extern "C" void guava_imgui_end_popup(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::EndPopup();
}

extern "C" bool guava_imgui_begin_combo(const char* label, size_t label_len,
                                        const char* preview,
                                        size_t preview_len) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  const std::string owned_preview =
      preview != nullptr ? make_string(preview, preview_len) : std::string{};
  return ImGui::BeginCombo(owned_label.c_str(), preview != nullptr
                                                    ? owned_preview.c_str()
                                                    : nullptr);
}

extern "C" void guava_imgui_end_combo(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::EndCombo();
}

extern "C" bool guava_imgui_menu_item(const char* label, size_t label_len,
                                      const char* shortcut, size_t shortcut_len,
                                      bool selected, bool enabled) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  const std::string owned_shortcut =
      shortcut != nullptr ? make_string(shortcut, shortcut_len) : std::string();
  return ImGui::MenuItem(owned_label.c_str(),
                         shortcut != nullptr ? owned_shortcut.c_str() : nullptr,
                         selected, enabled);
}

extern "C" bool guava_imgui_button(const char* label, size_t label_len) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::Button(owned_label.c_str());
}

extern "C" bool guava_imgui_button_ex(const char* label, size_t label_len,
                                      float width, float height) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::Button(owned_label.c_str(), ImVec2(width, height));
}

extern "C" bool guava_imgui_image_button(const char* id, size_t id_len,
                                         void* texture, float width,
                                         float height, float uv0_x, float uv0_y,
                                         float uv1_x, float uv1_y, float bg_r,
                                         float bg_g, float bg_b, float bg_a,
                                         float tint_r, float tint_g,
                                         float tint_b, float tint_a) {
  if (!g_imgui_initialized || texture == nullptr) {
    return false;
  }
  const std::string owned_id = make_string(id, id_len);
  return ImGui::ImageButton(
      owned_id.c_str(), reinterpret_cast<ImTextureID>(texture),
      ImVec2(width, height), ImVec2(uv0_x, uv0_y), ImVec2(uv1_x, uv1_y),
      ImVec4(bg_r, bg_g, bg_b, bg_a), ImVec4(tint_r, tint_g, tint_b, tint_a));
}

extern "C" bool guava_imgui_invisible_button(const char* id, size_t id_len,
                                             float width, float height) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_id = make_string(id, id_len);
  return ImGui::InvisibleButton(owned_id.c_str(), ImVec2(width, height));
}

extern "C" void guava_imgui_dummy(float width, float height) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::Dummy(ImVec2(width, height));
}

extern "C" void guava_imgui_spacing(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::Spacing();
}

extern "C" void guava_imgui_new_line(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::NewLine();
}

extern "C" void guava_imgui_bullet(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::Bullet();
}

extern "C" void guava_imgui_bullet_text(const char* text, size_t text_len) {
  if (!g_imgui_initialized) {
    return;
  }
  const std::string owned_text = make_string(text, text_len);
  ImGui::BulletText("%s", owned_text.c_str());
}

extern "C" void guava_imgui_same_line(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SameLine();
}

extern "C" void guava_imgui_same_line_ex(float offset_from_start_x,
                                         float spacing) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SameLine(offset_from_start_x, spacing);
}

extern "C" void guava_imgui_separator(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::Separator();
}

extern "C" void guava_imgui_separator_text(const char* text, size_t text_len) {
  if (!g_imgui_initialized) {
    return;
  }
  const std::string owned_text = make_string(text, text_len);
  ImGui::SeparatorText(owned_text.c_str());
}

extern "C" void guava_imgui_set_next_item_width(float width) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetNextItemWidth(width);
}

extern "C" void guava_imgui_set_next_item_open(bool is_open, int32_t cond) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetNextItemOpen(is_open, static_cast<ImGuiCond>(cond));
}

extern "C" void guava_imgui_set_next_window_pos(float x, float y) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetNextWindowPos(ImVec2(x, y));
}

extern "C" void guava_imgui_set_next_window_size(float width, float height) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetNextWindowSize(ImVec2(width, height));
}

extern "C" void guava_imgui_set_next_window_size_constraints(float min_w,
                                                             float min_h,
                                                             float max_w,
                                                             float max_h) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetNextWindowSizeConstraints(ImVec2(min_w, min_h),
                                      ImVec2(max_w, max_h));
}

extern "C" void guava_imgui_set_next_window_bg_alpha(float alpha) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetNextWindowBgAlpha(alpha);
}

extern "C" void guava_imgui_push_style_color(uint32_t slot, float r, float g,
                                             float b, float a) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PushStyleColor(to_imgui_style_color(slot), ImVec4(r, g, b, a));
}

extern "C" void guava_imgui_pop_style_color(int32_t count) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PopStyleColor(count);
}

extern "C" void guava_imgui_set_style_color(uint32_t color_idx, float r,
                                            float g, float b, float a) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGuiStyle& style = ImGui::GetStyle();
  if (color_idx < ImGuiCol_COUNT) {
    style.Colors[color_idx] = ImVec4(r, g, b, a);
  }
}

extern "C" void guava_imgui_set_style_var_float(uint32_t var_idx, float value) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGuiStyle& style = ImGui::GetStyle();
  switch (var_idx) {
    case 100:  // WindowBorderSize
      style.WindowBorderSize = value;
      break;
    case 101:  // FrameBorderSize
      style.FrameBorderSize = value;
      break;
    case 102:  // FrameRounding
      style.FrameRounding = value;
      break;
    default:
      break;
  }
}

extern "C" void guava_imgui_push_style_var_float(uint32_t slot, float value) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PushStyleVar(to_imgui_style_var(slot), value);
}

extern "C" void guava_imgui_push_style_var_vec2(uint32_t slot, float x,
                                                float y) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PushStyleVar(to_imgui_style_var(slot), ImVec2(x, y));
}

extern "C" void guava_imgui_pop_style_var(int32_t count) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PopStyleVar(count);
}

extern "C" bool guava_imgui_begin_child(const char* id, size_t id_len,
                                        float width, float height,
                                        bool border) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_id = make_string(id, id_len);
  return ImGui::BeginChild(owned_id.c_str(), ImVec2(width, height), border);
}

extern "C" void guava_imgui_end_child(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::EndChild();
}

extern "C" bool guava_imgui_begin_table(const char* id, size_t id_len,
                                        int32_t columns) {
  if (!g_imgui_initialized || columns <= 0) {
    return false;
  }
  const std::string owned_id = make_string(id, id_len);
  constexpr ImGuiTableFlags flags = ImGuiTableFlags_RowBg |
                                    ImGuiTableFlags_SizingStretchProp |
                                    ImGuiTableFlags_Resizable;
  return ImGui::BeginTable(owned_id.c_str(), columns, flags);
}

extern "C" void guava_imgui_end_table(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::EndTable();
}

extern "C" void guava_imgui_columns(int32_t count, const char* id,
                                    size_t id_len, bool border) {
  if (!g_imgui_initialized) {
    return;
  }
  const std::string owned_id =
      id != nullptr ? make_string(id, id_len) : std::string();
  ImGui::Columns(count, id != nullptr ? owned_id.c_str() : nullptr, border);
}

extern "C" void guava_imgui_next_column(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::NextColumn();
}

extern "C" void guava_imgui_table_setup_column(const char* label,
                                               size_t label_len, bool stretch,
                                               float init_width_or_weight) {
  if (!g_imgui_initialized) {
    return;
  }
  const std::string owned_label = make_string(label, label_len);
  const ImGuiTableColumnFlags flags = stretch
                                          ? ImGuiTableColumnFlags_WidthStretch
                                          : ImGuiTableColumnFlags_WidthFixed;
  ImGui::TableSetupColumn(owned_label.c_str(), flags, init_width_or_weight);
}

extern "C" void guava_imgui_table_headers_row(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::TableHeadersRow();
}

extern "C" void guava_imgui_table_next_row(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::TableNextRow();
}

extern "C" void guava_imgui_table_next_column(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::TableNextColumn();
}

extern "C" bool guava_imgui_selectable(const char* label, size_t label_len,
                                       bool selected, bool span_all_columns,
                                       float width, float height) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  ImGuiSelectableFlags flags = ImGuiSelectableFlags_None;
  if (span_all_columns) {
    flags |= ImGuiSelectableFlags_SpanAllColumns;
  }
  return ImGui::Selectable(owned_label.c_str(), selected, flags,
                           ImVec2(width, height));
}

extern "C" void guava_imgui_text(const char* text, size_t text_len) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::TextUnformatted(text, text + text_len);
}

extern "C" void guava_imgui_text_wrapped(const char* text, size_t text_len) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PushTextWrapPos(0.0f);
  ImGui::TextUnformatted(text, text + text_len);
  ImGui::PopTextWrapPos();
}

extern "C" void guava_imgui_label_text(const char* label, size_t label_len,
                                       const char* text, size_t text_len) {
  if (!g_imgui_initialized) {
    return;
  }
  const std::string owned_label = make_string(label, label_len);
  const std::string owned_text = make_string(text, text_len);
  constexpr float min_inline_value_width = 88.0f;
  constexpr float min_label_width = 84.0f;
  constexpr float max_label_width = 152.0f;
  const float available_width = ImGui::GetContentRegionAvail().x;
  const float spacing = ImGui::GetStyle().ItemInnerSpacing.x;
  const ImVec2 label_size = ImGui::CalcTextSize(owned_label.c_str());
  float label_width =
      std::clamp(available_width * 0.34f, min_label_width, max_label_width);
  label_width = (std::max)(label_width, label_size.x + spacing + 4.0f);

  ImGui::AlignTextToFramePadding();
  ImGui::TextUnformatted(owned_label.c_str());
  ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.72f, 0.74f, 0.79f, 1.0f));
  if (available_width >= label_width + min_inline_value_width) {
    ImGui::SameLine(label_width, spacing);
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextWrapped("%s", owned_text.c_str());
    ImGui::PopTextWrapPos();
  } else {
    ImGui::TextWrapped("%s", owned_text.c_str());
  }
  ImGui::PopStyleColor();
}

extern "C" void guava_imgui_push_id_u64(uint64_t value) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PushID(reinterpret_cast<void*>(static_cast<uintptr_t>(value)));
}

extern "C" void guava_imgui_pop_id(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PopID();
}

extern "C" bool guava_imgui_tree_node(const char* label, size_t label_len) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::TreeNode(owned_label.c_str());
}

extern "C" bool guava_imgui_tree_node_ex(const char* label, size_t label_len,
                                         uint32_t flags) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::TreeNodeEx(owned_label.c_str(),
                           static_cast<ImGuiTreeNodeFlags>(flags));
}

extern "C" void guava_imgui_tree_pop(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::TreePop();
}

extern "C" bool guava_imgui_is_item_clicked(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsItemClicked();
}

extern "C" bool guava_imgui_is_item_active(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsItemActive();
}

extern "C" bool guava_imgui_is_item_hovered(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsItemHovered();
}

extern "C" bool guava_imgui_is_item_deactivated_after_edit(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsItemDeactivatedAfterEdit();
}

extern "C" bool guava_imgui_input_text(const char* label, size_t label_len,
                                       char* buffer, size_t buffer_size) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::InputText(owned_label.c_str(), buffer, buffer_size);
}

extern "C" bool guava_imgui_input_text_multiline(const char* label,
                                                 size_t label_len, char* buffer,
                                                 size_t buffer_size,
                                                 float width, float height) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::InputTextMultiline(owned_label.c_str(), buffer, buffer_size,
                                   ImVec2(width, height));
}

extern "C" bool guava_imgui_input_text_with_hint(const char* label,
                                                 size_t label_len,
                                                 const char* hint,
                                                 size_t hint_len, char* buffer,
                                                 size_t buffer_size) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  const std::string owned_hint = make_string(hint, hint_len);
  return ImGui::InputTextWithHint(owned_label.c_str(), owned_hint.c_str(),
                                  buffer, buffer_size);
}

extern "C" bool guava_imgui_input_text_with_hint_flags(
    const char* label, size_t label_len, const char* hint, size_t hint_len,
    char* buffer, size_t buffer_size, uint32_t flags) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  const std::string owned_hint = make_string(hint, hint_len);
  return ImGui::InputTextWithHint(owned_label.c_str(), owned_hint.c_str(),
                                  buffer, buffer_size,
                                  static_cast<ImGuiInputTextFlags>(flags));
}

extern "C" bool guava_imgui_input_text_password(const char* label,
                                                size_t label_len, char* buffer,
                                                size_t buffer_size) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::InputText(owned_label.c_str(), buffer, buffer_size,
                          ImGuiInputTextFlags_Password);
}

extern "C" bool guava_imgui_drag_float(const char* label, size_t label_len,
                                       float* value, float speed,
                                       float min_value, float max_value) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::DragFloat(owned_label.c_str(), value, speed, min_value,
                          max_value);
}

extern "C" bool guava_imgui_drag_float3(const char* label, size_t label_len,
                                        float value[3], float speed,
                                        float min_value, float max_value) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::DragFloat3(owned_label.c_str(), value, speed, min_value,
                           max_value);
}

extern "C" bool guava_imgui_slider_float(const char* label, size_t label_len,
                                         float* value, float min_value,
                                         float max_value) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::SliderFloat(owned_label.c_str(), value, min_value, max_value);
}

extern "C" bool guava_imgui_slider_angle(const char* label, size_t label_len,
                                         float* value_radians,
                                         float min_degrees, float max_degrees) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::SliderAngle(owned_label.c_str(), value_radians, min_degrees,
                            max_degrees);
}

extern "C" bool guava_imgui_slider_int(const char* label, size_t label_len,
                                       int* value, int min_value,
                                       int max_value) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::SliderInt(owned_label.c_str(), value, min_value, max_value);
}

extern "C" bool guava_imgui_input_float(const char* label, size_t label_len,
                                        float* value, float step,
                                        float step_fast) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::InputFloat(owned_label.c_str(), value, step, step_fast);
}

extern "C" bool guava_imgui_input_int(const char* label, size_t label_len,
                                      int* value, int step, int step_fast) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::InputInt(owned_label.c_str(), value, step, step_fast);
}

extern "C" bool guava_imgui_checkbox(const char* label, size_t label_len,
                                     bool* value) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::Checkbox(owned_label.c_str(), value);
}

extern "C" bool guava_imgui_radio_button(const char* label, size_t label_len,
                                         bool active) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::RadioButton(owned_label.c_str(), active);
}

extern "C" void guava_imgui_progress_bar(float fraction, float width,
                                         float height, const char* overlay,
                                         size_t overlay_len) {
  if (!g_imgui_initialized) {
    return;
  }
  const char* overlay_ptr = nullptr;
  std::string owned_overlay;
  if (overlay != nullptr) {
    owned_overlay = make_string(overlay, overlay_len);
    overlay_ptr = owned_overlay.c_str();
  }
  ImGui::ProgressBar(fraction, ImVec2(width, height), overlay_ptr);
}

extern "C" bool guava_imgui_collapsing_header(const char* label,
                                              size_t label_len,
                                              bool default_open) {
  if (!g_imgui_initialized) {
    return false;
  }
  ImGuiTreeNodeFlags flags =
      default_open ? ImGuiTreeNodeFlags_DefaultOpen : ImGuiTreeNodeFlags_None;
  const std::string owned_label = make_string(label, label_len);
  return ImGui::CollapsingHeader(owned_label.c_str(), flags);
}

extern "C" bool guava_imgui_begin_drag_drop_source_u64(const char* payload_type,
                                                       size_t payload_type_len,
                                                       uint64_t value) {
  if (!g_imgui_initialized) {
    return false;
  }
  if (!ImGui::BeginDragDropSource()) {
    return false;
  }

  const std::string owned_type = make_string(payload_type, payload_type_len);
  ImGui::SetDragDropPayload(owned_type.c_str(), &value, sizeof(value));
  return true;
}

extern "C" void guava_imgui_end_drag_drop_source(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::EndDragDropSource();
}

extern "C" bool guava_imgui_drag_drop_source_u64(const char* payload_type,
                                                 size_t payload_type_len,
                                                 uint64_t value,
                                                 const char* preview_text,
                                                 size_t preview_text_len) {
  if (!guava_imgui_begin_drag_drop_source_u64(payload_type, payload_type_len,
                                              value)) {
    return false;
  }
  if (preview_text != nullptr and preview_text_len > 0) {
    ImGui::TextUnformatted(preview_text, preview_text + preview_text_len);
  }
  guava_imgui_end_drag_drop_source();
  return true;
}

extern "C" bool guava_imgui_accept_drag_drop_payload_u64(
    const char* payload_type, size_t payload_type_len, uint64_t* out_value) {
  if (!g_imgui_initialized || out_value == nullptr) {
    return false;
  }
  if (!ImGui::BeginDragDropTarget()) {
    return false;
  }

  bool accepted = false;
  const std::string owned_type = make_string(payload_type, payload_type_len);
  if (const ImGuiPayload* payload =
          ImGui::AcceptDragDropPayload(owned_type.c_str())) {
    if (payload->Data != nullptr &&
        payload->DataSize == static_cast<int>(sizeof(uint64_t))) {
      *out_value = *static_cast<const uint64_t*>(payload->Data);
      accepted = true;
    }
  }

  ImGui::EndDragDropTarget();
  return accepted;
}

extern "C" bool guava_imgui_is_window_hovered(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsWindowHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem);
}

extern "C" bool guava_imgui_is_window_focused(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsWindowFocused(ImGuiFocusedFlags_RootAndChildWindows);
}

extern "C" bool guava_imgui_is_key_pressed(int32_t key, bool repeat) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsKeyPressed(static_cast<ImGuiKey>(key), repeat);
}

extern "C" bool guava_imgui_is_key_down(int32_t key) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsKeyDown(static_cast<ImGuiKey>(key));
}

extern "C" bool guava_imgui_is_key_released(int32_t key) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsKeyReleased(static_cast<ImGuiKey>(key));
}

extern "C" bool guava_imgui_get_key_ctrl(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::GetIO().KeyCtrl;
}

extern "C" bool guava_imgui_get_key_shift(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::GetIO().KeyShift;
}

extern "C" bool guava_imgui_get_key_alt(void) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::GetIO().KeyAlt;
}

extern "C" void guava_imgui_get_content_region_avail(float out_value[2]) {
  if (!g_imgui_initialized || out_value == nullptr) {
    return;
  }
  const ImVec2 value = ImGui::GetContentRegionAvail();
  out_value[0] = value.x;
  out_value[1] = value.y;
}

extern "C" void guava_imgui_get_window_pos(float out_value[2]) {
  if (!g_imgui_initialized || out_value == nullptr) {
    return;
  }
  const ImVec2 value = ImGui::GetWindowPos();
  out_value[0] = value.x;
  out_value[1] = value.y;
}

extern "C" void guava_imgui_get_cursor_screen_pos(float out_value[2]) {
  if (!g_imgui_initialized || out_value == nullptr) {
    return;
  }
  const ImVec2 value = ImGui::GetCursorScreenPos();
  out_value[0] = value.x;
  out_value[1] = value.y;
}

extern "C" void guava_imgui_set_cursor_pos(float x, float y) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetCursorPos(ImVec2(x, y));
}

extern "C" void guava_imgui_set_cursor_pos_y(float y) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetCursorPosY(y);
}

extern "C" void guava_imgui_align_text_to_frame_padding(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::AlignTextToFramePadding();
}

extern "C" void guava_imgui_indent(float width) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::Indent(width);
}

extern "C" void guava_imgui_unindent(float width) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::Unindent(width);
}

extern "C" void guava_imgui_get_window_size(float out_value[2]) {
  if (!g_imgui_initialized) {
    out_value[0] = 0.0f;
    out_value[1] = 0.0f;
    return;
  }
  const ImVec2 value = ImGui::GetWindowSize();
  out_value[0] = value.x;
  out_value[1] = value.y;
}

extern "C" void guava_imgui_set_tooltip(const char* text, size_t text_len) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetTooltip("%.*s", (int)text_len, text);
}

extern "C" float guava_imgui_get_frame_height(void) {
  if (!g_imgui_initialized) {
    return 0.0f;
  }
  return ImGui::GetFrameHeight();
}

extern "C" float guava_imgui_get_font_size(void) {
  if (!g_imgui_initialized) {
    return 0.0f;
  }
  return ImGui::GetFontSize();
}

extern "C" float guava_imgui_get_text_line_height(void) {
  if (!g_imgui_initialized) {
    return 0.0f;
  }
  return ImGui::GetTextLineHeight();
}

extern "C" void guava_imgui_calc_text_size(const char* text, size_t text_len,
                                           bool hide_text_after_double_hash,
                                           float wrap_width,
                                           float out_value[2]) {
  if (out_value == nullptr) {
    return;
  }
  if (!g_imgui_initialized) {
    out_value[0] = 0.0f;
    out_value[1] = 0.0f;
    return;
  }
  const std::string owned_text = make_string(text, text_len);
  const ImVec2 size = ImGui::CalcTextSize(
      owned_text.c_str(), nullptr, hide_text_after_double_hash, wrap_width);
  out_value[0] = size.x;
  out_value[1] = size.y;
}

extern "C" float guava_imgui_get_time(void) {
  if (!g_imgui_initialized) {
    return 0.0f;
  }
  return static_cast<float>(ImGui::GetTime());
}

extern "C" void guava_imgui_set_scroll_here_y(float center_y_ratio) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetScrollHereY(center_y_ratio);
}

extern "C" void guava_imgui_set_keyboard_focus_here(int32_t offset) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetKeyboardFocusHere(offset);
}

extern "C" void guava_imgui_image(void* texture, float width, float height,
                                  float uv0_x, float uv0_y, float uv1_x,
                                  float uv1_y) {
  if (!g_imgui_initialized || texture == nullptr) {
    return;
  }
  ImGui::Image((ImTextureID)(intptr_t)texture, ImVec2(width, height),
               ImVec2(uv0_x, uv0_y), ImVec2(uv1_x, uv1_y));
}

extern "C" bool guava_imgui_begin_tab_bar(const char* id, size_t id_len) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_id = make_string(id, id_len);
  return ImGui::BeginTabBar(owned_id.c_str());
}

extern "C" void guava_imgui_end_tab_bar(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::EndTabBar();
}

extern "C" bool guava_imgui_begin_tab_item(const char* label, size_t label_len,
                                           uint32_t flags) {
  if (!g_imgui_initialized) {
    return false;
  }
  const std::string owned_label = make_string(label, label_len);
  return ImGui::BeginTabItem(owned_label.c_str(), nullptr,
                             static_cast<ImGuiTabItemFlags>(flags));
}

extern "C" void guava_imgui_end_tab_item(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::EndTabItem();
}

extern "C" void guava_imgui_push_clip_rect(float min_x, float min_y,
                                           float max_x, float max_y,
                                           bool intersect_with_current) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PushClipRect(ImVec2(min_x, min_y), ImVec2(max_x, max_y),
                      intersect_with_current);
}

extern "C" void guava_imgui_pop_clip_rect(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PopClipRect();
}

// ── Extended widget API ──

extern "C" bool guava_imgui_drag_float4(const char* label, size_t label_len,
                                        float value[4], float speed,
                                        float min_value, float max_value) {
  if (!g_imgui_initialized) {
    return false;
  }
  char buf[256];
  size_t n = label_len < sizeof(buf) - 1 ? label_len : sizeof(buf) - 1;
  memcpy(buf, label, n);
  buf[n] = '\0';
  return ImGui::DragFloat4(buf, value, speed, min_value, max_value);
}

extern "C" bool guava_imgui_drag_int(const char* label, size_t label_len,
                                     int* value, float speed, int min_value,
                                     int max_value) {
  if (!g_imgui_initialized) {
    return false;
  }
  char buf[256];
  size_t n = label_len < sizeof(buf) - 1 ? label_len : sizeof(buf) - 1;
  memcpy(buf, label, n);
  buf[n] = '\0';
  return ImGui::DragInt(buf, value, speed, min_value, max_value);
}

extern "C" bool guava_imgui_color_edit3(const char* label, size_t label_len,
                                        float color[3]) {
  if (!g_imgui_initialized) {
    return false;
  }
  char buf[256];
  size_t n = label_len < sizeof(buf) - 1 ? label_len : sizeof(buf) - 1;
  memcpy(buf, label, n);
  buf[n] = '\0';
  return ImGui::ColorEdit3(buf, color);
}

extern "C" bool guava_imgui_color_edit4(const char* label, size_t label_len,
                                        float color[4]) {
  if (!g_imgui_initialized) {
    return false;
  }
  char buf[256];
  size_t n = label_len < sizeof(buf) - 1 ? label_len : sizeof(buf) - 1;
  memcpy(buf, label, n);
  buf[n] = '\0';
  return ImGui::ColorEdit4(buf, color);
}

extern "C" bool guava_imgui_color_picker4(const char* label, size_t label_len,
                                          float color[4]) {
  if (!g_imgui_initialized) {
    return false;
  }
  char buf[256];
  size_t n = label_len < sizeof(buf) - 1 ? label_len : sizeof(buf) - 1;
  memcpy(buf, label, n);
  buf[n] = '\0';
  return ImGui::ColorPicker4(buf, color);
}

extern "C" void guava_imgui_text_colored(float r, float g, float b, float a,
                                         const char* text, size_t text_len) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(r, g, b, a));
  ImGui::TextUnformatted(text, text + text_len);
  ImGui::PopStyleColor();
}

extern "C" void guava_imgui_begin_group(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::BeginGroup();
}

extern "C" void guava_imgui_end_group(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::EndGroup();
}

extern "C" void guava_imgui_set_item_default_focus(void) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetItemDefaultFocus();
}

extern "C" void guava_imgui_set_cursor_screen_pos(float x, float y) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::SetCursorScreenPos(ImVec2(x, y));
}

extern "C" bool guava_imgui_is_mouse_double_clicked(int button) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsMouseDoubleClicked(static_cast<ImGuiMouseButton>(button));
}

extern "C" bool guava_imgui_is_mouse_dragging(int button) {
  if (!g_imgui_initialized) {
    return false;
  }
  return ImGui::IsMouseDragging(static_cast<ImGuiMouseButton>(button));
}

extern "C" void guava_imgui_get_mouse_drag_delta(int button,
                                                 float out_value[2]) {
  if (!g_imgui_initialized || out_value == nullptr) {
    return;
  }
  ImVec2 d = ImGui::GetMouseDragDelta(static_cast<ImGuiMouseButton>(button));
  out_value[0] = d.x;
  out_value[1] = d.y;
}

extern "C" void guava_imgui_reset_mouse_drag_delta(int button) {
  if (!g_imgui_initialized) {
    return;
  }
  ImGui::ResetMouseDragDelta(static_cast<ImGuiMouseButton>(button));
}
