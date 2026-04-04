#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include "window_native_handles.h"
#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>
#include <SDL3/SDL_properties.h>
#include <SDL3/SDL_video.h>

namespace {

NSWindow* guava_ns_window_from_sdl(SDL_Window* window) {
    if (window == nullptr) {
        return nil;
    }

    const SDL_PropertiesID properties = SDL_GetWindowProperties(window);
    if (properties == 0) {
        return nil;
    }

    void* cocoa_window = SDL_GetPointerProperty(properties, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);
    if (cocoa_window == nullptr) {
        return nil;
    }

    return (__bridge NSWindow*)cocoa_window;
}

} // namespace

extern "C" bool guava_window_create_metal_layer_binding(void* window_handle, GuavaMetalLayerBinding* out_binding) {
    if (window_handle == nullptr || out_binding == nullptr) {
        return false;
    }

    SDL_MetalView metal_view = SDL_Metal_CreateView(static_cast<SDL_Window*>(window_handle));
    if (metal_view == nullptr) {
        return false;
    }

    void* raw_layer = SDL_Metal_GetLayer(metal_view);
    if (raw_layer == nullptr) {
        SDL_Metal_DestroyView(metal_view);
        return false;
    }

    out_binding->metal_view = metal_view;
    out_binding->layer = raw_layer;
    return true;
}

extern "C" void guava_window_destroy_metal_layer_binding(GuavaMetalLayerBinding binding) {
    if (binding.metal_view != nullptr) {
        SDL_Metal_DestroyView((SDL_MetalView)binding.metal_view);
    }
}

extern "C" void* guava_window_get_native_cocoa_window(void* window_handle) {
    NSWindow* native_window = guava_ns_window_from_sdl(static_cast<SDL_Window*>(window_handle));
    if (native_window == nil) {
        return nullptr;
    }

    return (__bridge void*)native_window;
}

extern "C" bool guava_window_apply_macos_native_titlebar_style(SDL_Window* window) {
    @autoreleasepool {
        NSWindow* native_window = guava_ns_window_from_sdl(window);
        if (native_window == nil) {
            return false;
        }

        native_window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        native_window.titleVisibility = NSWindowTitleHidden;
        native_window.titlebarAppearsTransparent = YES;
        native_window.movable = NO;
        native_window.movableByWindowBackground = NO;

        NSWindowCollectionBehavior behavior = native_window.collectionBehavior;
        behavior &= ~NSWindowCollectionBehaviorFullScreenPrimary;
        behavior &= ~NSWindowCollectionBehaviorFullScreenAuxiliary;
        behavior |= NSWindowCollectionBehaviorFullScreenNone;
        native_window.collectionBehavior = behavior;
        return true;
    }
}

extern "C" float guava_window_macos_titlebar_leading_inset(SDL_Window* window) {
    @autoreleasepool {
        NSWindow* native_window = guava_ns_window_from_sdl(window);
        if (native_window == nil) {
            return 0.0f;
        }

        NSButton* zoom_button = [native_window standardWindowButton:NSWindowZoomButton];
        if (zoom_button == nil) {
            return 0.0f;
        }

        return static_cast<float>(NSMaxX(zoom_button.frame) + 12.0);
    }
}

extern "C" void guava_window_activate_macos_app(void) {
    @autoreleasepool {
        [NSApp activate];
    }
}

extern "C" void guava_window_set_background_app(void) {
    @autoreleasepool {
        // NSApplicationActivationPolicyAccessory: no Dock icon, no Cmd-Tab entry.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}

extern "C" bool guava_window_begin_macos_native_drag(SDL_Window* window) {
    @autoreleasepool {
        NSWindow* native_window = guava_ns_window_from_sdl(window);
        if (native_window == nil) {
            return false;
        }

        NSEvent* event = [NSApp currentEvent];
        if (event == nil) {
            return false;
        }

        if (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeLeftMouseDragged) {
            return false;
        }

        [native_window performWindowDragWithEvent:event];
        return true;
    }
}

extern "C" bool guava_window_attach_to_parent_nsview(void* child_sdl_window, void* parent_nsview_ptr) {
    @autoreleasepool {
        if (child_sdl_window == nullptr || parent_nsview_ptr == nullptr) {
            return false;
        }

        NSWindow* child_window = guava_ns_window_from_sdl(static_cast<SDL_Window*>(child_sdl_window));
        if (child_window == nil) {
            return false;
        }

        // Safety: the parent pointer may come from a different process (e.g.
        // Electron) and be invalid in our address space. Wrap ObjC messaging
        // in @try/@catch to prevent a segfault from killing the engine.
        @try {
            NSView* parent_view = (__bridge NSView*)parent_nsview_ptr;
            NSWindow* parent_window = [parent_view window];
            if (parent_window == nil) {
                return false;
            }

            // Remove from previous parent if any
            NSWindow* current_parent = [child_window parentWindow];
            if (current_parent != nil) {
                [current_parent removeChildWindow:child_window];
            }

            // Attach as child — child moves with parent, stays on top
            [parent_window addChildWindow:child_window ordered:NSWindowAbove];

            // Make child window borderless and non-activating
            child_window.styleMask = NSWindowStyleMaskBorderless;
            child_window.level = parent_window.level;

            return true;
        } @catch (NSException* exception) {
            NSLog(@"[Guava] attachToParent failed: %@ — %@", exception.name, exception.reason);
            return false;
        }
    }
}

extern "C" bool guava_window_detach_from_parent(void* child_sdl_window) {
    @autoreleasepool {
        if (child_sdl_window == nullptr) {
            return false;
        }

        NSWindow* child_window = guava_ns_window_from_sdl(static_cast<SDL_Window*>(child_sdl_window));
        if (child_window == nil) {
            return false;
        }

        NSWindow* parent = [child_window parentWindow];
        if (parent != nil) {
            [parent removeChildWindow:child_window];
        }
        return true;
    }
}
