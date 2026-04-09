// citron_shell.mm — macOS implementation of the Citron Shell (C ABI).
//
// Architecture:
//   1. NSWindow with a Metal layer (full window) for final composition.
//   2. CEF off-screen rendering (OSR) — Chromium runs headless, delivers
//      BGRA+alpha pixel buffers via OnPaint when the DOM changes.
//   3. Engine renders 3D scene to an IOSurface.
//   4. Composition pass: Metal shader alpha-blends UI texture over 3D scene.
//   5. Input events are routed to CEF or reported as viewport events.
//
// This file implements:
//   - CefApp + CefBrowserProcessHandler (process lifecycle)
//   - CefClient + CefRenderHandler (OSR pixel delivery)
//   - CefLifeSpanHandler (browser creation/destruction)
//   - CitronShell C ABI functions

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <IOSurface/IOSurface.h>

// CEF headers (C++ API)
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_render_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

#include "citron.h"

#include <mutex>
#include <atomic>
#include <cstring>
#include <fstream>
#include <sstream>

// ══════════════════════════════════════════════════════════════════════════
// ── Metal Composition Shader ─────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════

static const char* kCompositionShaderSource = R"(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Full-screen triangle (no vertex buffer needed).
vertex VertexOut composition_vertex(uint vid [[vertex_id]]) {
    VertexOut out;
    // Generate a full-screen triangle: vertices at (-1,-1), (3,-1), (-1,3)
    float2 pos = float2((vid << 1) & 2, vid & 2);
    out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(pos.x, 1.0 - pos.y);  // Flip Y for texture sampling
    return out;
}

// Composite: draw scene_texture in viewport rect, alpha-blend ui_texture over everything.
fragment float4 composition_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> scene_tex [[texture(0)]],
    texture2d<float> ui_tex    [[texture(1)]],
    constant float4& viewport_rect [[buffer(0)]]  // normalized (x, y, w, h)
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);

    float2 uv = in.uv;
    float4 scene_color = float4(0.0);

    // Check if this fragment is within the viewport rectangle.
    float2 vp_min = viewport_rect.xy;
    float2 vp_max = viewport_rect.xy + viewport_rect.zw;

    if (viewport_rect.z > 0.0 && viewport_rect.w > 0.0 &&
        uv.x >= vp_min.x && uv.x <= vp_max.x &&
        uv.y >= vp_min.y && uv.y <= vp_max.y) {
        // Map to scene texture UV.
        float2 scene_uv = (uv - vp_min) / viewport_rect.zw;
        scene_color = scene_tex.sample(s, scene_uv);
    }

    // Sample UI texture (covers full window, has alpha).
    float4 ui_color = ui_tex.sample(s, uv);

    // Alpha-blend: UI over scene.
    // The viewport area in the UI MUST have alpha=0 (transparent CSS background)
    // so the 3D scene shows through.  Outside the viewport, UI alpha is 1.
    float4 result;
    result.rgb = ui_color.rgb + scene_color.rgb * (1.0 - ui_color.a);
    result.a = 1.0;

    return result;
}
)";

// ══════════════════════════════════════════════════════════════════════════
// ── CitronShell Internal State ────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════

struct CitronShell {
    // Window
    NSWindow*        window       = nil;
    NSView*          metalView    = nil;
    CAMetalLayer*    metalLayer   = nil;
    
    // Metal
    id<MTLDevice>              device         = nil;
    id<MTLCommandQueue>        commandQueue   = nil;
    id<MTLRenderPipelineState> pipeline       = nil;
    id<MTLTexture>             uiTexture      = nil;   // CEF UI (BGRA+alpha)
    id<MTLTexture>             sceneTexture   = nil;   // 3D scene from IOSurface
    id<MTLBuffer>              viewportBuffer = nil;    // viewport rect (normalized)
    
    // CEF
    CefRefPtr<CefBrowser> browser;
    
    // Viewport rect in CSS points (top-left origin).
    int32_t vpX = 0, vpY = 0, vpW = 0, vpH = 0;
    
    // UI texture state
    std::mutex       uiMutex;
    std::atomic<bool> uiDirty{false};
    int32_t          uiWidth  = 0;
    int32_t          uiHeight = 0;
    std::vector<uint8_t> uiPixels;  // BGRA pixel buffer from CEF
    
    // Scene surface
    IOSurfaceRef     sceneSurface = nullptr;
    uint32_t         sceneIOSurfaceId = 0;
    
    // JS bridge
    CitronMessageCallback messageCallback = nullptr;
    void*                messageUserdata = nullptr;
    
    // State
    std::atomic<bool> running{true};
    bool              devToolsEnabled = false;
    float             scaleFactor = 1.0f;
    int32_t           windowWidth = 0;
    int32_t           windowHeight = 0;
};

// Global shell pointer (for CEF callbacks which can't take user data).
static CitronShell* g_shell = nullptr;

// Preload script content (loaded once, injected into every page context).
static std::string g_preloadScript;

// ══════════════════════════════════════════════════════════════════════════
// ── CEF Handler Classes ──────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════

// ── CefRenderHandler: receives OSR pixel buffers ─────────────────────────

class ShellRenderHandler : public CefRenderHandler {
public:
    void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override {
        if (!g_shell) { rect.Set(0, 0, 1, 1); return; }
        // Return DIP (logical/CSS points) — CEF multiplies by device_scale_factor.
        rect.Set(0, 0, g_shell->windowWidth, g_shell->windowHeight);
    }

    bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& screen_info) override {
        if (!g_shell) return false;
        screen_info.device_scale_factor = g_shell->scaleFactor;
        return true;
    }

    void OnPaint(CefRefPtr<CefBrowser> browser,
                 PaintElementType type,
                 const RectList& dirtyRects,
                 const void* buffer,
                 int width, int height) override {
        if (!g_shell || type != PET_VIEW) return;

        static int paintCount = 0;
        ++paintCount;
        if (paintCount <= 15 || paintCount % 60 == 0) {
            // Sample center pixel alpha for diagnostics
            int cx = width / 2, cy = height / 2;
            const uint8_t* px = (const uint8_t*)buffer + ((size_t)cy * width + cx) * 4;
            NSLog(@"[Citron] OnPaint #%d: %dx%d — center BGRA=(%d,%d,%d,%d) alpha=%s",
                  paintCount, width, height,
                  px[0], px[1], px[2], px[3],
                  px[3] == 0 ? "TRANSPARENT" : "OPAQUE");
        }

        size_t dataSize = (size_t)width * height * 4;

        std::lock_guard<std::mutex> lock(g_shell->uiMutex);
        g_shell->uiPixels.resize(dataSize);
        std::memcpy(g_shell->uiPixels.data(), buffer, dataSize);
        g_shell->uiWidth = width;
        g_shell->uiHeight = height;
        g_shell->uiDirty.store(true, std::memory_order_release);
    }

    IMPLEMENT_REFCOUNTING(ShellRenderHandler);
};

// ── CefLifeSpanHandler ───────────────────────────────────────────────────

class ShellLifeSpanHandler : public CefLifeSpanHandler {
public:
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        if (g_shell) {
            g_shell->browser = browser;
            NSLog(@"[Citron] CEF browser created (id=%d)", browser->GetIdentifier());
        }
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        if (g_shell) {
            g_shell->browser = nullptr;
        }
    }

    IMPLEMENT_REFCOUNTING(ShellLifeSpanHandler);
};

// ── CefClient: routes handler requests ───────────────────────────────────

class ShellDisplayHandler : public CefDisplayHandler {
public:
    bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                          cef_log_severity_t level,
                          const CefString& message,
                          const CefString& source,
                          int line) override {
        const char* levelStr = "I";
        if (level == LOGSEVERITY_WARNING) levelStr = "W";
        else if (level >= LOGSEVERITY_ERROR) levelStr = "E";
        NSLog(@"[CEF/%s] %s (%s:%d)", levelStr,
              message.ToString().c_str(),
              source.ToString().c_str(), line);
        return false;  // Let CEF also log it
    }
    IMPLEMENT_REFCOUNTING(ShellDisplayHandler);
};

class ShellLoadHandler : public CefLoadHandler {
public:
    void OnLoadStart(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     TransitionType transition_type) override {
        if (frame->IsMain()) {
            NSLog(@"[Citron] OnLoadStart: %s", frame->GetURL().ToString().c_str());
        }
    }

    void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   int httpStatusCode) override {
        if (frame->IsMain()) {
            NSLog(@"[Citron] OnLoadEnd: status=%d url=%s", httpStatusCode,
                  frame->GetURL().ToString().c_str());
        }
    }

    void OnLoadError(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     ErrorCode errorCode,
                     const CefString& errorText,
                     const CefString& failedUrl) override {
        NSLog(@"[Citron] OnLoadError: code=%d text=%s url=%s",
              errorCode, errorText.ToString().c_str(),
              failedUrl.ToString().c_str());
    }

    IMPLEMENT_REFCOUNTING(ShellLoadHandler);
};

class ShellClient : public CefClient {
public:
    ShellClient()
        : renderHandler_(new ShellRenderHandler())
        , lifeSpanHandler_(new ShellLifeSpanHandler())
        , displayHandler_(new ShellDisplayHandler())
        , loadHandler_(new ShellLoadHandler()) {}

    CefRefPtr<CefRenderHandler> GetRenderHandler() override { return renderHandler_; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return lifeSpanHandler_; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return displayHandler_; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return loadHandler_; }

    // Handle messages from JS → Native (via CefProcessMessage).
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  CefProcessId source_process,
                                  CefRefPtr<CefProcessMessage> message) override {
        if (message->GetName() == "citron_message") {
            auto args = message->GetArgumentList();
            if (args->GetSize() >= 1 && g_shell && g_shell->messageCallback) {
                CefString json = args->GetString(0);
                std::string jsonStr = json.ToString();
                g_shell->messageCallback(jsonStr.c_str(), (uint32_t)jsonStr.size(),
                                         g_shell->messageUserdata);
            }
            return true;
        }
        return false;
    }

    IMPLEMENT_REFCOUNTING(ShellClient);

private:
    CefRefPtr<ShellRenderHandler>  renderHandler_;
    CefRefPtr<ShellLifeSpanHandler> lifeSpanHandler_;
    CefRefPtr<ShellDisplayHandler>  displayHandler_;
    CefRefPtr<ShellLoadHandler>     loadHandler_;
};

// ── CefV8Handler: handles window.citron.invoke() / postMessage() calls ───

class CitronV8Handler : public CefV8Handler {
public:
    bool Execute(const CefString& name,
                 CefRefPtr<CefV8Value> object,
                 const CefV8ValueList& arguments,
                 CefRefPtr<CefV8Value>& retval,
                 CefString& exception) override {

        if (name == "postMessage" && arguments.size() >= 1) {
            // window.citron.postMessage(jsonString)
            // Send JSON string to browser process via CefProcessMessage.
            CefString json = arguments[0]->IsString()
                ? arguments[0]->GetStringValue()
                : CefString("{}");

            auto context = CefV8Context::GetCurrentContext();
            auto browser = context->GetBrowser();
            auto frame = context->GetFrame();

            auto msg = CefProcessMessage::Create("citron_message");
            msg->GetArgumentList()->SetString(0, json);
            frame->SendProcessMessage(PID_BROWSER, msg);

            retval = CefV8Value::CreateBool(true);
            return true;
        }

        if (name == "invoke" && arguments.size() >= 1) {
            // window.citron.invoke(method, params) → Promise
            // Serialize as JSON: {"method": ..., "params": ...}
            // For now, wrap in a simple JSON envelope and send via postMessage path.
            CefString method = arguments[0]->GetStringValue();

            // Build JSON manually (avoid needing a JSON library).
            std::string json = "{\"method\":\"";
            json += method.ToString();
            json += "\"";
            if (arguments.size() >= 2 && arguments[1]->IsString()) {
                json += ",\"params\":";
                json += arguments[1]->GetStringValue().ToString();
            }
            json += "}";

            auto context = CefV8Context::GetCurrentContext();
            auto browser = context->GetBrowser();
            auto frame = context->GetFrame();

            auto msg = CefProcessMessage::Create("citron_message");
            msg->GetArgumentList()->SetString(0, json);
            frame->SendProcessMessage(PID_BROWSER, msg);

            // Return undefined (not a real Promise yet — TODO: implement request/response).
            retval = CefV8Value::CreateUndefined();
            return true;
        }

        return false;
    }

    IMPLEMENT_REFCOUNTING(CitronV8Handler);
};

// ── CefRenderProcessHandler: injects window.citron into every page ───────

class ShellRenderProcessHandler : public CefRenderProcessHandler {
public:
    void OnContextCreated(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefV8Context> context) override {
        NSLog(@"[Citron] OnContextCreated called for frame=%s url=%s",
              frame->GetIdentifier().ToString().c_str(),
              frame->GetURL().ToString().c_str());
        // Create window.citron object.
        auto global = context->GetGlobal();
        auto citronObj = CefV8Value::CreateObject(nullptr, nullptr);

        CefRefPtr<CitronV8Handler> handler(new CitronV8Handler());

        // window.citron.postMessage(json)
        citronObj->SetValue("postMessage",
            CefV8Value::CreateFunction("postMessage", handler),
            V8_PROPERTY_ATTRIBUTE_READONLY);

        // window.citron.invoke(method, paramsJson)
        citronObj->SetValue("invoke",
            CefV8Value::CreateFunction("invoke", handler),
            V8_PROPERTY_ATTRIBUTE_READONLY);

        // window.citron.isNative = true
        citronObj->SetValue("isNative",
            CefV8Value::CreateBool(true),
            V8_PROPERTY_ATTRIBUTE_READONLY);

        // window.citron.platform = "macos"
        citronObj->SetValue("platform",
            CefV8Value::CreateString("macos"),
            V8_PROPERTY_ATTRIBUTE_READONLY);

        // window.citron._handleNative = function(msg) {} — placeholder, overwritten by JS
        citronObj->SetValue("_handleNative",
            CefV8Value::CreateFunction("_handleNative", handler),
            V8_PROPERTY_ATTRIBUTE_NONE);

        global->SetValue("citron", citronObj, V8_PROPERTY_ATTRIBUTE_READONLY);

        // Inject the preload script that creates window.guavaEngine bridge.
        if (!g_preloadScript.empty()) {
            frame->ExecuteJavaScript(g_preloadScript, "citron-preload.js", 0);
        }

        NSLog(@"[Citron] JS bridge injected (frame=%s)", frame->GetIdentifier().ToString().c_str());
    }

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  CefProcessId source_process,
                                  CefRefPtr<CefProcessMessage> message) override {
        // Handle messages from browser process → renderer (for citron_send_to_js).
        if (message->GetName() == "citron_to_js") {
            auto args = message->GetArgumentList();
            if (args->GetSize() >= 1) {
                CefString js = "window.citron && window.citron._handleNative && window.citron._handleNative(";
                std::string code = js.ToString() + args->GetString(0).ToString() + ")";
                frame->ExecuteJavaScript(code, frame->GetURL(), 0);
            }
            return true;
        }
        return false;
    }

    IMPLEMENT_REFCOUNTING(ShellRenderProcessHandler);
};

// ── CefApp: process-level setup ──────────────────────────────────────────

class ShellApp : public CefApp,
                 public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return renderProcessHandler_; }

    void OnBeforeCommandLineProcessing(
        const CefString& process_type,
        CefRefPtr<CefCommandLine> command_line) override {
        // Disable GPU process — we're doing OSR, CEF doesn't need its own GPU.
        command_line->AppendSwitch("disable-gpu");
        command_line->AppendSwitch("disable-gpu-compositing");
        // Run in single-process mode (no separate helper exe needed).
        command_line->AppendSwitch("single-process");
        // Disable Chromium Safe Storage to avoid keychain access prompts.
        command_line->AppendSwitch("use-mock-keychain");
    }

    IMPLEMENT_REFCOUNTING(ShellApp);

private:
    CefRefPtr<ShellRenderProcessHandler> renderProcessHandler_{new ShellRenderProcessHandler()};
};

// ══════════════════════════════════════════════════════════════════════════
// ── Metal Setup ──────────────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════

static bool SetupMetal(CitronShell* shell) {
    shell->device = MTLCreateSystemDefaultDevice();
    if (!shell->device) {
        NSLog(@"[Citron] Metal not available");
        return false;
    }

    shell->commandQueue = [shell->device newCommandQueue];

    // Compile composition shader.
    NSError* error = nil;
    NSString* source = [NSString stringWithUTF8String:kCompositionShaderSource];
    id<MTLLibrary> library = [shell->device newLibraryWithSource:source options:nil error:&error];
    if (error) {
        NSLog(@"[Citron] Shader compile error: %@", error);
        return false;
    }

    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"composition_vertex"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"composition_fragment"];

    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vertexFunc;
    desc.fragmentFunction = fragmentFunc;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    // Enable alpha blending (for the composition pass itself — but we handle blending in shader).
    desc.colorAttachments[0].blendingEnabled = NO;

    shell->pipeline = [shell->device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (error) {
        NSLog(@"[Citron] Pipeline error: %@", error);
        return false;
    }

    // Viewport uniform buffer.
    shell->viewportBuffer = [shell->device newBufferWithLength:sizeof(float) * 4
                                                      options:MTLResourceStorageModeShared];

    return true;
}

// ── Update UI Texture from CEF pixels ────────────────────────────────────

static void UpdateUITexture(CitronShell* shell) {
    if (!shell->uiDirty.load(std::memory_order_acquire)) return;

    std::lock_guard<std::mutex> lock(shell->uiMutex);

    int32_t w = shell->uiWidth;
    int32_t h = shell->uiHeight;
    if (w <= 0 || h <= 0 || shell->uiPixels.empty()) return;

    // Recreate texture if size changed.
    if (!shell->uiTexture ||
        (int32_t)[shell->uiTexture width] != w ||
        (int32_t)[shell->uiTexture height] != h) {

        MTLTextureDescriptor* desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                        width:w
                                       height:h
                                    mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        shell->uiTexture = [shell->device newTextureWithDescriptor:desc];
    }

    // Upload pixels.
    MTLRegion region = MTLRegionMake2D(0, 0, w, h);
    [shell->uiTexture replaceRegion:region
                        mipmapLevel:0
                          withBytes:shell->uiPixels.data()
                        bytesPerRow:w * 4];

    shell->uiDirty.store(false, std::memory_order_release);
}

// ── Update Scene Texture from IOSurface ──────────────────────────────────

static void UpdateSceneTexture(CitronShell* shell) {
    if (!shell->sceneSurface) return;

    size_t sw = IOSurfaceGetWidth(shell->sceneSurface);
    size_t sh = IOSurfaceGetHeight(shell->sceneSurface);

    // Recreate texture if size changed. 
    if (!shell->sceneTexture ||
        [shell->sceneTexture width] != sw ||
        [shell->sceneTexture height] != sh) {

        MTLTextureDescriptor* desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                        width:sw
                                       height:sh
                                    mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        shell->sceneTexture = [shell->device newTextureWithDescriptor:desc
                                                          iosurface:shell->sceneSurface
                                                              plane:0];
    }
}

// ── Composition Render Pass ──────────────────────────────────────────────

static void RenderComposition(CitronShell* shell) {
    if (!shell->metalLayer || !shell->pipeline) return;

    @autoreleasepool {
        id<CAMetalDrawable> drawable = [shell->metalLayer nextDrawable];
        if (!drawable) return;

        // Update viewport uniform (normalized coordinates).
        float* vp = (float*)[shell->viewportBuffer contents];
        float ww = (float)shell->windowWidth * shell->scaleFactor;
        float wh = (float)shell->windowHeight * shell->scaleFactor;
        if (ww > 0 && wh > 0) {
            vp[0] = (float)(shell->vpX * shell->scaleFactor) / ww;
            vp[1] = (float)(shell->vpY * shell->scaleFactor) / wh;
            vp[2] = (float)(shell->vpW * shell->scaleFactor) / ww;
            vp[3] = (float)(shell->vpH * shell->scaleFactor) / wh;
        }

        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = drawable.texture;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.118, 0.118, 0.180, 1.0);

        id<MTLCommandBuffer> cmdBuf = [shell->commandQueue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];

        [enc setRenderPipelineState:shell->pipeline];

        // Bind textures (scene + UI).
        if (shell->sceneTexture)
            [enc setFragmentTexture:shell->sceneTexture atIndex:0];
        if (shell->uiTexture)
            [enc setFragmentTexture:shell->uiTexture atIndex:1];

        [enc setFragmentBuffer:shell->viewportBuffer offset:0 atIndex:0];

        // Draw full-screen triangle (3 vertices, no vertex buffer).
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];

        [cmdBuf presentDrawable:drawable];
        [cmdBuf commit];
    }
}

// ══════════════════════════════════════════════════════════════════════════
// ── NSWindow Delegate ────────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════

@interface CitronWindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation CitronWindowDelegate

- (void)windowDidResize:(NSNotification*)notification {
    if (!g_shell) return;
    NSWindow* win = notification.object;
    NSRect frame = [win contentLayoutRect];
    g_shell->windowWidth = (int32_t)frame.size.width;
    g_shell->windowHeight = (int32_t)frame.size.height;
    g_shell->scaleFactor = (float)win.backingScaleFactor;

    // Resize Metal layer.
    if (g_shell->metalLayer) {
        CGSize drawableSize = CGSizeMake(
            frame.size.width * win.backingScaleFactor,
            frame.size.height * win.backingScaleFactor);
        g_shell->metalLayer.drawableSize = drawableSize;
    }

    // Notify CEF of size change.
    if (g_shell->browser) {
        g_shell->browser->GetHost()->NotifyMoveOrResizeStarted();
        g_shell->browser->GetHost()->WasResized();
    }
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
    if (g_shell) {
        g_shell->running.store(false);
        if (g_shell->browser) {
            g_shell->browser->GetHost()->CloseBrowser(true);
        }
    }
    return YES;
}

@end

// ══════════════════════════════════════════════════════════════════════════
// ── C ABI Implementation ─────────────────────────────────────────────────
// ══════════════════════════════════════════════════════════════════════════

extern "C" {

CitronShell* citron_create(const CitronConfig* config) {
    if (!config) return nullptr;

    // Only one shell at a time.
    if (g_shell) {
        NSLog(@"[Citron] ERROR: shell already exists");
        return nullptr;
    }

    auto* shell = new CitronShell();
    g_shell = shell;

    shell->windowWidth = config->width;
    shell->windowHeight = config->height;
    shell->vpX = config->viewport_x;
    shell->vpY = config->viewport_y;
    shell->vpW = config->viewport_w;
    shell->vpH = config->viewport_h;
    shell->devToolsEnabled = config->dev_tools;

    // ── Load preload script (citron-preload.js) ─────────────────────────
    {
        // Try: 1) Bundle resource, 2) executable-relative, 3) source tree
        NSString* preloadPath = [[NSBundle mainBundle] pathForResource:@"citron-preload" ofType:@"js"];
        if (!preloadPath) {
            // Fallback: next to the executable (for development builds)
            NSString* exeDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
            preloadPath = [exeDir stringByAppendingPathComponent:@"citron-preload.js"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:preloadPath]) {
                // Fallback: source tree (development)
                preloadPath = [exeDir stringByAppendingPathComponent:@"../../../src/citron-preload.js"];
            }
        }
        if (preloadPath && [[NSFileManager defaultManager] fileExistsAtPath:preloadPath]) {
            std::ifstream f([preloadPath UTF8String]);
            std::ostringstream ss;
            ss << f.rdbuf();
            g_preloadScript = ss.str();
            NSLog(@"[Citron] Preload script loaded (%zu bytes) from %@", g_preloadScript.size(), preloadPath);
        } else {
            NSLog(@"[Citron] WARNING: citron-preload.js not found");
        }
    }

    // ── Load CEF framework library (required on macOS before any CEF API call) ──
    static CefScopedLibraryLoader cefLibraryLoader;
    if (!cefLibraryLoader.LoadInMain()) {
        NSLog(@"[Citron] Failed to load CEF framework library");
        delete shell;
        g_shell = nullptr;
        return nullptr;
    }

    // ── Initialize CEF ───────────────────────────────────────────────────
    CefMainArgs mainArgs;
    CefRefPtr<ShellApp> app(new ShellApp());

    CefSettings settings;
    settings.windowless_rendering_enabled = true;
    settings.no_sandbox = true;
    settings.log_severity = LOGSEVERITY_WARNING;
    settings.command_line_args_disabled = false;

    // Set a separate cache path to avoid conflicts with Electron's Chromium instance.
    NSString* cacheDir = [NSString stringWithFormat:@"%@/Library/Caches/Citron",
                          NSHomeDirectory()];
    CefString(&settings.root_cache_path) = [cacheDir UTF8String];

    if (!CefInitialize(mainArgs, settings, app, nullptr)) {
        NSLog(@"[Citron] CEF initialization failed");
        delete shell;
        g_shell = nullptr;
        return nullptr;
    }

    // ── Create NSWindow ──────────────────────────────────────────────────
    NSRect frame = NSMakeRect(0, 0, config->width, config->height);

    NSWindowStyleMask style = config->frameless
        ? NSWindowStyleMaskBorderless
        : (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
           NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable);

    shell->window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:style
                    backing:NSBackingStoreBuffered
                      defer:NO];

    shell->window.title = config->title
        ? [NSString stringWithUTF8String:config->title]
        : @"Guava Editor";
    shell->window.backgroundColor = [NSColor colorWithRed:0.118 green:0.118 blue:0.180 alpha:1.0];
    shell->window.minSize = NSMakeSize(800, 600);

    static CitronWindowDelegate* windowDelegate = [[CitronWindowDelegate alloc] init];
    shell->window.delegate = windowDelegate;

    shell->scaleFactor = (float)shell->window.backingScaleFactor;

    // ── Set up Metal layer ───────────────────────────────────────────────
    if (!SetupMetal(shell)) {
        CefShutdown();
        delete shell;
        g_shell = nullptr;
        return nullptr;
    }

    shell->metalView = shell->window.contentView;
    [shell->metalView setWantsLayer:YES];

    shell->metalLayer = [CAMetalLayer layer];
    shell->metalLayer.device = shell->device;
    shell->metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    shell->metalLayer.framebufferOnly = YES;
    shell->metalLayer.drawableSize = CGSizeMake(
        config->width * shell->scaleFactor,
        config->height * shell->scaleFactor);
    shell->metalView.layer = shell->metalLayer;

    // ── Create CEF browser (OSR) ─────────────────────────────────────────
    CefWindowInfo windowInfo;
    windowInfo.SetAsWindowless(0);

    CefBrowserSettings browserSettings;
    browserSettings.windowless_frame_rate = 60;
    browserSettings.background_color = CefColorSetARGB(0, 0, 0, 0);  // Transparent for composition
    CefString(&browserSettings.default_encoding) = "UTF-8";

    CefRefPtr<ShellClient> client(new ShellClient());
    std::string url = config->url ? config->url : "about:blank";

    CefBrowserHost::CreateBrowser(windowInfo, client, url, browserSettings, nullptr, nullptr);

    // ── Show window ──────────────────────────────────────────────────────
    [shell->window center];
    [shell->window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    NSLog(@"[Citron] Shell created: %dx%d, url=%s", config->width, config->height, url.c_str());

    return shell;
}

void citron_destroy(CitronShell* shell) {
    if (!shell) return;

    if (shell->browser) {
        shell->browser->GetHost()->CloseBrowser(true);
        shell->browser = nullptr;
    }

    if (shell->sceneSurface) {
        CFRelease(shell->sceneSurface);
        shell->sceneSurface = nullptr;
    }

    CefShutdown();

    if (shell->window) {
        [shell->window close];
        shell->window = nil;
    }

    g_shell = nullptr;
    delete shell;
}

bool citron_tick(CitronShell* shell) {
    if (!shell || !shell->running.load()) return false;

    // Process CEF messages (non-blocking).
    CefDoMessageLoopWork();

    // Process macOS events (non-blocking).
    @autoreleasepool {
        NSEvent* event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                           untilDate:nil
                                              inMode:NSDefaultRunLoopMode
                                             dequeue:YES])) {
            [NSApp sendEvent:event];
        }
    }

    // Update textures and render composition.
    UpdateUITexture(shell);
    UpdateSceneTexture(shell);
    RenderComposition(shell);

    return shell->running.load();
}

bool citron_should_continue(const CitronShell* shell) {
    return shell && shell->running.load();
}

void citron_set_viewport_rect(CitronShell* shell,
                                    int32_t x, int32_t y,
                                    int32_t w, int32_t h) {
    if (!shell) return;
    shell->vpX = x;
    shell->vpY = y;
    shell->vpW = w;
    shell->vpH = h;
}

void citron_set_scene_surface(CitronShell* shell, uint32_t iosurface_id) {
    if (!shell) return;

    if (shell->sceneSurface) {
        CFRelease(shell->sceneSurface);
        shell->sceneSurface = nullptr;
        shell->sceneTexture = nil;
    }

    if (iosurface_id == 0) return;

    IOSurfaceRef surface = IOSurfaceLookup(iosurface_id);
    if (!surface) {
        NSLog(@"[Citron] IOSurfaceLookup(%u) failed", iosurface_id);
        return;
    }

    shell->sceneSurface = surface;
    shell->sceneIOSurfaceId = iosurface_id;

    size_t sw = IOSurfaceGetWidth(surface);
    size_t sh = IOSurfaceGetHeight(surface);

    MTLTextureDescriptor* desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                    width:sw
                                   height:sh
                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    shell->sceneTexture = [shell->device newTextureWithDescriptor:desc
                                                      iosurface:surface
                                                          plane:0];

    NSLog(@"[Citron] Scene surface set: id=%u size=%zux%zu", iosurface_id, sw, sh);
}

void citron_send_mouse(CitronShell* shell,
                             CitronMouseEventType type,
                             int32_t x, int32_t y,
                             CitronMouseButton button,
                             float delta_x, float delta_y,
                             uint32_t modifiers) {
    if (!shell || !shell->browser) return;

    CefMouseEvent cefEvent;
    cefEvent.x = x;
    cefEvent.y = y;
    cefEvent.modifiers = 0;
    if (modifiers & CITRON_MOD_SHIFT) cefEvent.modifiers |= EVENTFLAG_SHIFT_DOWN;
    if (modifiers & CITRON_MOD_CTRL)  cefEvent.modifiers |= EVENTFLAG_CONTROL_DOWN;
    if (modifiers & CITRON_MOD_ALT)   cefEvent.modifiers |= EVENTFLAG_ALT_DOWN;
    if (modifiers & CITRON_MOD_META)  cefEvent.modifiers |= EVENTFLAG_COMMAND_DOWN;

    auto host = shell->browser->GetHost();

    switch (type) {
        case CITRON_MOUSE_MOVE:
            host->SendMouseMoveEvent(cefEvent, false);
            break;
        case CITRON_MOUSE_DOWN: {
            cef_mouse_button_type_t cefBtn = (button == CITRON_MOUSE_BUTTON_RIGHT)
                ? MBT_RIGHT : (button == CITRON_MOUSE_BUTTON_MIDDLE) ? MBT_MIDDLE : MBT_LEFT;
            host->SendMouseClickEvent(cefEvent, cefBtn, false, 1);
            break;
        }
        case CITRON_MOUSE_UP: {
            cef_mouse_button_type_t cefBtn = (button == CITRON_MOUSE_BUTTON_RIGHT)
                ? MBT_RIGHT : (button == CITRON_MOUSE_BUTTON_MIDDLE) ? MBT_MIDDLE : MBT_LEFT;
            host->SendMouseClickEvent(cefEvent, cefBtn, true, 1);
            break;
        }
        case CITRON_MOUSE_SCROLL:
            host->SendMouseWheelEvent(cefEvent, (int)delta_x, (int)delta_y);
            break;
        case CITRON_MOUSE_ENTER:
            host->SendMouseMoveEvent(cefEvent, false);
            break;
        case CITRON_MOUSE_LEAVE:
            host->SendMouseMoveEvent(cefEvent, true);
            break;
    }
}

void citron_send_key(CitronShell* shell,
                           CitronKeyEventType type,
                           int32_t key_code,
                           const char* characters,
                           uint32_t modifiers) {
    if (!shell || !shell->browser) return;

    CefKeyEvent cefEvent;
    cefEvent.native_key_code = key_code;
    cefEvent.modifiers = 0;
    if (modifiers & CITRON_MOD_SHIFT) cefEvent.modifiers |= EVENTFLAG_SHIFT_DOWN;
    if (modifiers & CITRON_MOD_CTRL)  cefEvent.modifiers |= EVENTFLAG_CONTROL_DOWN;
    if (modifiers & CITRON_MOD_ALT)   cefEvent.modifiers |= EVENTFLAG_ALT_DOWN;
    if (modifiers & CITRON_MOD_META)  cefEvent.modifiers |= EVENTFLAG_COMMAND_DOWN;

    switch (type) {
        case CITRON_KEY_DOWN:
            cefEvent.type = KEYEVENT_RAWKEYDOWN;
            break;
        case CITRON_KEY_UP:
            cefEvent.type = KEYEVENT_KEYUP;
            break;
        case CITRON_KEY_CHAR:
            cefEvent.type = KEYEVENT_CHAR;
            if (characters && characters[0]) {
                cefEvent.character = characters[0];
                cefEvent.unmodified_character = characters[0];
            }
            break;
    }

    shell->browser->GetHost()->SendKeyEvent(cefEvent);
}

const void* citron_get_ui_pixels(const CitronShell* shell,
                                       int32_t* out_width,
                                       int32_t* out_height) {
    if (!shell) return nullptr;
    if (out_width) *out_width = shell->uiWidth;
    if (out_height) *out_height = shell->uiHeight;
    return shell->uiPixels.empty() ? nullptr : shell->uiPixels.data();
}

bool citron_ui_dirty(const CitronShell* shell) {
    return shell && shell->uiDirty.load(std::memory_order_acquire);
}

void citron_ui_mark_clean(CitronShell* shell) {
    if (shell) shell->uiDirty.store(false, std::memory_order_release);
}

void citron_on_message(CitronShell* shell,
                             CitronMessageCallback callback,
                             void* userdata) {
    if (!shell) return;
    shell->messageCallback = callback;
    shell->messageUserdata = userdata;
}

void citron_eval_js(CitronShell* shell, const char* code) {
    if (!shell || !shell->browser || !code) return;
    auto frame = shell->browser->GetMainFrame();
    if (frame) {
        frame->ExecuteJavaScript(code, frame->GetURL(), 0);
    }
}

void citron_send_to_js(CitronShell* shell, const char* json, uint32_t json_len) {
    if (!shell || !shell->browser || !json) return;
    std::string js = "window.citron && window.citron._handleNative(";
    js.append(json, json_len);
    js += ")";
    auto frame = shell->browser->GetMainFrame();
    if (frame) {
        frame->ExecuteJavaScript(js, frame->GetURL(), 0);
    }
}

void citron_resize(CitronShell* shell, int32_t width, int32_t height) {
    if (!shell || !shell->window) return;
    NSRect frame = [shell->window frame];
    frame.size.width = width;
    frame.size.height = height;
    [shell->window setFrame:frame display:YES animate:NO];
}

void citron_get_size(const CitronShell* shell, int32_t* width, int32_t* height) {
    if (!shell) return;
    if (width) *width = shell->windowWidth;
    if (height) *height = shell->windowHeight;
}

float citron_get_scale_factor(const CitronShell* shell) {
    return shell ? shell->scaleFactor : 1.0f;
}

void* citron_get_native_handle(const CitronShell* shell) {
    return shell ? (__bridge void*)shell->window : nullptr;
}

void citron_show_dev_tools(CitronShell* shell) {
    if (!shell || !shell->browser) return;
    // Open DevTools in a separate popup window.
    CefWindowInfo devToolsInfo;
    CefBrowserSettings devToolsSettings;
    shell->browser->GetHost()->ShowDevTools(devToolsInfo, nullptr, devToolsSettings, CefPoint());
}

} // extern "C"
