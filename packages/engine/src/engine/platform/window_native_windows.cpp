#include "window_native_handles.h"
#include <SDL3/SDL.h>
#include <SDL3/SDL_properties.h>
#include <SDL3/SDL_video.h>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <uxtheme.h>

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

#ifndef WM_NCUAHDRAWCAPTION
#define WM_NCUAHDRAWCAPTION 0x00AE
#endif

#ifndef WM_NCUAHDRAWFRAME
#define WM_NCUAHDRAWFRAME 0x00AF
#endif

namespace {

constexpr UINT_PTR kGuavaWindowSubclassId = 0x47555641;

HWND guava_hwnd_from_sdl(SDL_Window* window) {
    if (window == nullptr) {
        return nullptr;
    }

    const SDL_PropertiesID properties = SDL_GetWindowProperties(window);
    if (properties == 0) {
        return nullptr;
    }

    return static_cast<HWND>(SDL_GetPointerProperty(properties, SDL_PROP_WINDOW_WIN32_HWND_POINTER, nullptr));
}

bool guava_is_valid_rect(const RECT& rect) {
    return rect.left >= 0 && rect.top >= 0 && rect.right > rect.left && rect.bottom > rect.top;
}

int guava_resize_border_x() {
    return GetSystemMetrics(SM_CXSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
}

int guava_resize_border_y() {
    return GetSystemMetrics(SM_CYSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
}

LRESULT guava_hit_test_resize_border(HWND hwnd, LPARAM l_param) {
    if (IsZoomed(hwnd)) {
        return HTCLIENT;
    }

    RECT window_rect = {};
    if (!GetWindowRect(hwnd, &window_rect)) {
        return HTCLIENT;
    }

    const POINT cursor = {
        GET_X_LPARAM(l_param),
        GET_Y_LPARAM(l_param),
    };

    const int border_x = guava_resize_border_x();
    const int border_y = guava_resize_border_y();
    const bool left = cursor.x >= window_rect.left && cursor.x < window_rect.left + border_x;
    const bool right = cursor.x < window_rect.right && cursor.x >= window_rect.right - border_x;
    const bool top = cursor.y >= window_rect.top && cursor.y < window_rect.top + border_y;
    const bool bottom = cursor.y < window_rect.bottom && cursor.y >= window_rect.bottom - border_y;

    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
    return HTCLIENT;
}

LRESULT CALLBACK guava_window_subclass_proc(
    HWND hwnd,
    UINT message,
    WPARAM w_param,
    LPARAM l_param,
    UINT_PTR subclass_id,
    DWORD_PTR ref_data
) {
    (void)ref_data;

    LRESULT dwm_result = 0;
    if (message == WM_NCHITTEST && DwmDefWindowProc(hwnd, message, w_param, l_param, &dwm_result)) {
        return dwm_result;
    }

    switch (message) {
        case WM_NCCALCSIZE:
            if (w_param == TRUE) {
                NCCALCSIZE_PARAMS* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(l_param);
                if (params == nullptr) {
                    return 0;
                }

                if (IsZoomed(hwnd)) {
                    const int border_x = guava_resize_border_x();
                    const int border_y = guava_resize_border_y();
                    params->rgrc[0].left += border_x;
                    params->rgrc[0].right -= border_x;
                    params->rgrc[0].bottom -= border_y;
                    params->rgrc[0].top += border_y;
                }
                return 0;
            }
            break;
        case WM_NCHITTEST:
            return guava_hit_test_resize_border(hwnd, l_param);
        case WM_NCUAHDRAWCAPTION:
        case WM_NCUAHDRAWFRAME:
            return 0;
        case WM_NCDESTROY:
            RemoveWindowSubclass(hwnd, guava_window_subclass_proc, subclass_id);
            break;
        default:
            break;
    }

    return DefSubclassProc(hwnd, message, w_param, l_param);
}

float guava_fallback_caption_button_width() {
    return static_cast<float>(GetSystemMetrics(SM_CXSIZE) * 3 + GetSystemMetrics(SM_CXPADDEDBORDER) * 2 + 24);
}

} // namespace

extern "C" void* guava_window_get_native_win32_hwnd(void* window_handle) {
    return guava_hwnd_from_sdl(static_cast<SDL_Window*>(window_handle));
}

extern "C" bool guava_window_apply_windows_native_titlebar_style(SDL_Window* window) {
    HWND hwnd = guava_hwnd_from_sdl(window);
    if (hwnd == nullptr) {
        return false;
    }

    const DWORD mask = WTNCA_NODRAWCAPTION | WTNCA_NODRAWICON;
    const HRESULT theme_result = SetWindowThemeNonClientAttributes(hwnd, mask, mask);
    if (FAILED(theme_result)) {
        return false;
    }

    const BOOL allow_nc_paint = TRUE;
    (void)DwmSetWindowAttribute(hwnd, DWMWA_ALLOW_NCPAINT, &allow_nc_paint, sizeof(allow_nc_paint));

    const BOOL dark_mode = TRUE;
    (void)DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark_mode, sizeof(dark_mode));

    if (!SetWindowSubclass(hwnd, guava_window_subclass_proc, kGuavaWindowSubclassId, 0)) {
        return false;
    }

    SetWindowPos(
        hwnd,
        nullptr,
        0,
        0,
        0,
        0,
        SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER
    );
    return true;
}

extern "C" float guava_window_windows_titlebar_trailing_inset(SDL_Window* window) {
    HWND hwnd = guava_hwnd_from_sdl(window);
    if (hwnd == nullptr) {
        return 0.0f;
    }

    RECT client_rect = {};
    if (!GetClientRect(hwnd, &client_rect)) {
        return guava_fallback_caption_button_width();
    }

    RECT caption_bounds = {};
    if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CAPTION_BUTTON_BOUNDS, &caption_bounds, sizeof(caption_bounds))) &&
        guava_is_valid_rect(caption_bounds)) {
        const LONG width = client_rect.right - client_rect.left;
        const LONG inset = (width - caption_bounds.left) + 12;
        return static_cast<float>(inset > 0 ? inset : 0);
    }

    return guava_fallback_caption_button_width();
}
