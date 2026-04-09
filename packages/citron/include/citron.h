// citron.h — C ABI interface for the Citron shell.
//
// The shell provides:
//   1. A native window with Metal/Vulkan rendering
//   2. An off-screen CEF browser for the React UI
//   3. Composition: 3D scene + UI overlay in a single render pass
//   4. Input routing: viewport events → engine, UI events → CEF
//   5. JS ↔ Native message passing
//
// Usage:
//   CitronConfig cfg = { .width = 1440, .height = 900, ... };
//   CitronShell* shell = citron_create(&cfg);
//   while (citron_should_continue(shell)) {
//       citron_tick(shell);
//   }
//   citron_destroy(shell);

#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Opaque handle ────────────────────────────────────────────────────────
typedef struct CitronShell CitronShell;

// ── Configuration ────────────────────────────────────────────────────────

typedef struct {
    int32_t  width;             // Initial window width (CSS points)
    int32_t  height;            // Initial window height (CSS points)
    const char* title;          // Window title (UTF-8)
    const char* url;            // URL to load in CEF (dev: http://localhost:5173, prod: file:///...)
    bool     dev_tools;         // Enable Chrome DevTools
    bool     frameless;         // Borderless window (custom title bar)

    // Viewport defines the region within the window where the 3D scene is rendered.
    // The shell's composition pass draws scene_texture here and alpha-blends
    // the CEF UI texture everywhere.  Coordinates are CSS points from top-left.
    int32_t  viewport_x;
    int32_t  viewport_y;
    int32_t  viewport_w;
    int32_t  viewport_h;
} CitronConfig;

// ── Lifecycle ────────────────────────────────────────────────────────────

/// Create the shell.  Returns NULL on failure.
CitronShell* citron_create(const CitronConfig* config);

/// Destroy the shell and free all resources.
void citron_destroy(CitronShell* shell);

/// Run one iteration of the event loop (processes OS events + CEF messages).
/// Call this from your main loop.  Returns false if the window was closed.
bool citron_tick(CitronShell* shell);

/// Check if the shell is still running (window not closed).
bool citron_should_continue(const CitronShell* shell);

// ── Viewport ─────────────────────────────────────────────────────────────

/// Update the viewport rectangle (CSS points, top-left origin).
/// Called when the React layout changes the viewport panel's position/size.
void citron_set_viewport_rect(CitronShell* shell,
                               int32_t x, int32_t y,
                               int32_t w, int32_t h);

/// Provide the 3D scene texture for composition.
/// On macOS: iosurface_id from IOSurfaceGetID().
/// On Windows: TBD (ID3D12Resource* or VkImage handle).
/// On Linux: TBD (POSIX shm fd or VkImage handle).
/// The shell will sample this texture in the composition pass for the viewport region.
void citron_set_scene_surface(CitronShell* shell, uint32_t iosurface_id);

// ── Input ────────────────────────────────────────────────────────────────

typedef enum {
    CITRON_MOUSE_MOVE       = 0,
    CITRON_MOUSE_DOWN       = 1,
    CITRON_MOUSE_UP         = 2,
    CITRON_MOUSE_SCROLL     = 3,
    CITRON_MOUSE_ENTER      = 4,
    CITRON_MOUSE_LEAVE      = 5,
} CitronMouseEventType;

typedef enum {
    CITRON_MOUSE_BUTTON_LEFT   = 0,
    CITRON_MOUSE_BUTTON_RIGHT  = 1,
    CITRON_MOUSE_BUTTON_MIDDLE = 2,
} CitronMouseButton;

typedef enum {
    CITRON_KEY_DOWN   = 0,
    CITRON_KEY_UP     = 1,
    CITRON_KEY_CHAR   = 2,  // Character input (after IME processing)
} CitronKeyEventType;

typedef enum {
    CITRON_MOD_SHIFT = 1 << 0,
    CITRON_MOD_CTRL  = 1 << 1,
    CITRON_MOD_ALT   = 1 << 2,
    CITRON_MOD_META  = 1 << 3,  // Cmd on macOS, Win on Windows
} CitronModifiers;

/// Send a mouse event.  The shell routes it to CEF or reports it as a
/// viewport event based on the current viewport rect.
void citron_send_mouse(CitronShell* shell,
                        CitronMouseEventType type,
                        int32_t x, int32_t y,
                        CitronMouseButton button,
                        float delta_x, float delta_y,
                        uint32_t modifiers);

/// Send a keyboard event.  Routed to CEF or viewport based on focus.
void citron_send_key(CitronShell* shell,
                      CitronKeyEventType type,
                      int32_t key_code,
                      const char* characters,
                      uint32_t modifiers);

// ── UI Texture ───────────────────────────────────────────────────────────

/// Get the UI texture (CEF rendered output with alpha).
/// On macOS: returns a pointer to BGRA pixel data.  Only valid until next
/// citron_tick().  Check citron_ui_dirty() first.
/// `out_width` and `out_height` receive the texture dimensions.
const void* citron_get_ui_pixels(const CitronShell* shell,
                                  int32_t* out_width,
                                  int32_t* out_height);

/// Returns true if the UI texture has changed since the last call.
/// When false, you can skip re-uploading the UI texture to GPU.
bool citron_ui_dirty(const CitronShell* shell);

/// Mark the UI texture as consumed (resets dirty flag).
void citron_ui_mark_clean(CitronShell* shell);

// ── JavaScript Bridge ────────────────────────────────────────────────────

/// Callback for messages from JS.  `json` is a UTF-8 JSON string.
typedef void (*CitronMessageCallback)(const char* json, uint32_t json_len, void* userdata);

/// Register a handler for messages sent from JS via window.citron.postMessage().
void citron_on_message(CitronShell* shell,
                        CitronMessageCallback callback,
                        void* userdata);

/// Evaluate JavaScript in the CEF browser.
void citron_eval_js(CitronShell* shell, const char* code);

/// Send a JSON message to JS (calls window.citron._handleNative(msg)).
void citron_send_to_js(CitronShell* shell, const char* json, uint32_t json_len);

// ── Window ───────────────────────────────────────────────────────────────

/// Resize the window.
void citron_resize(CitronShell* shell, int32_t width, int32_t height);

/// Get current window size.
void citron_get_size(const CitronShell* shell, int32_t* width, int32_t* height);

/// Get the backing scale factor (DPR).
float citron_get_scale_factor(const CitronShell* shell);

/// Get the native window handle.
/// macOS: NSWindow*  |  Windows: HWND  |  Linux: GtkWindow*
void* citron_get_native_handle(const CitronShell* shell);

/// Show Chrome DevTools (CEF only).
void citron_show_dev_tools(CitronShell* shell);

#ifdef __cplusplus
}
#endif
// Citron — Native shell for the Guava Editor.
// Replaces Electron with AppKit + WKWebView + MTKView.
#pragma once

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <MetalKit/MetalKit.h>
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CVDisplayLink.h>

NS_ASSUME_NONNULL_BEGIN

// ── Forward declarations ─────────────────────────────────────────────────

@class CitronApp;
@class EditorWindow;
@class MetalViewport;
@class WebViewBridge;
@class EngineClient;

// ── EngineClient ─────────────────────────────────────────────────────────
// WebSocket JSON-RPC 2.0 client to the engine on ws://127.0.0.1:9100.

@interface EngineClient : NSObject <NSURLSessionWebSocketDelegate>

@property (nonatomic, readonly) BOOL connected;

- (void)connect;
- (void)disconnect;

/// JSON-RPC call with completion handler.  Result is the parsed "result" value.
- (void)call:(NSString*)method
      params:(NSDictionary* _Nullable)params
  completion:(void(^)(NSDictionary* _Nullable result, NSError* _Nullable error))completion;

/// Subscribe to push notifications from the engine.
- (void)onNotification:(NSString*)method
               handler:(void(^)(NSDictionary* params))handler;

@end

// ── MetalViewport ────────────────────────────────────────────────────────
// Displays the engine's IOSurface via CALayer, polled at VSync via CVDisplayLink.

@interface MetalViewport : NSView

/// Attach to an IOSurface by its global ID.
- (void)attachSurface:(uint32_t)surfaceId;

/// Update to a new IOSurface (e.g. after resize).
- (void)updateSurface:(uint32_t)surfaceId;

/// Detach and stop rendering.
- (void)detach;

@property (nonatomic, readonly) BOOL isAttached;

@end

// ── WebViewBridge ────────────────────────────────────────────────────────
// Manages a WKWebView that loads the React editor UI.
// Bridges JS ↔ Native messages via WKScriptMessageHandler.

typedef void(^WebViewMessageHandler)(NSDictionary* body);

@interface WebViewBridge : NSObject <WKScriptMessageHandler, WKNavigationDelegate>

@property (nonatomic, readonly) WKWebView* webView;

- (instancetype)initWithFrame:(NSRect)frame;

/// Load the React app from a URL (dev: localhost:5173, prod: file:// bundle).
- (void)loadURL:(NSURL*)url;

/// Evaluate JS in the web view.
- (void)evaluateJS:(NSString*)script completion:(void(^ _Nullable)(id _Nullable, NSError* _Nullable))completion;

/// Register a handler for messages from JS (window.citron.postMessage({...})).
- (void)setMessageHandler:(WebViewMessageHandler)handler;

/// Send a JSON message to JS (calls window.citron.onNativeMessage({...})).
- (void)sendToJS:(NSDictionary*)message;

@end

// ── EditorWindow ─────────────────────────────────────────────────────────
// Main editor window: NSSplitView with WKWebView (React) + MetalViewport.

@interface EditorWindow : NSWindow <NSSplitViewDelegate>

@property (nonatomic, strong) MetalViewport* viewport;
@property (nonatomic, strong) WebViewBridge* webBridge;
@property (nonatomic, strong) EngineClient* engine;

- (instancetype)initWithContentRect:(NSRect)contentRect;

@end

// ── CitronApp ────────────────────────────────────────────────────────────
// NSApplication delegate — creates the editor window and wires everything up.

@interface CitronApp : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) EditorWindow* mainWindow;

@end

NS_ASSUME_NONNULL_END
