// IOSurface native viewport addon for macOS.
//
// Three modes of operation:
//  A) **Native Overlay (preferred)**: createOverlay() inserts a CALayer backed
//     by the IOSurface directly into the Electron window's layer hierarchy.
//     A CVDisplayLink polls IOSurfaceGetSeed() at monitor refresh rate and
//     re-assigns layer.contents when a new frame is available — zero memcpy,
//     zero CPU→GPU upload, zero SharedArrayBuffer.  HTML overlays (ViewCube,
//     metrics) render on top via Chromium's compositor (the BrowserWindow is
//     created with `transparent: true` so the viewport div is see-through).
//
//  B) SharedArrayBuffer: setSharedBuffer(sab) then refreshShared() writes
//     pixels directly into the SAB; renderer polls via Atomics, zero IPC.
//     Used as fallback on Linux or when the overlay can't be created.
//
//  C) Legacy (IPC-based): refresh() → allocates Buffer, returns pixels + dims.

#import <IOSurface/IOSurface.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CVDisplayLink.h>
#include <napi.h>
#include <cstring>
#include <atomic>

static IOSurfaceRef g_surface = nullptr;

// ── SharedArrayBuffer state ──────────────────────────────────────────────
static uint8_t* g_sab_data = nullptr;   // pointer into SAB backing store
static size_t   g_sab_size = 0;         // total SAB size in bytes
static uint32_t g_sab_generation = 0;   // monotonic frame counter
static uint32_t g_write_index   = 0;    // ping-pong buffer index (0 or 1)
static uint32_t g_last_seed     = 0;    // IOSurface seed from last successful copy
static constexpr size_t SAB_HEADER_BYTES = 16;

// ── Native overlay state (forward-declared, initialised below) ───────────
static CALayer*         g_overlay_layer = nil;
static NSView*          g_host_view     = nil;
static CVDisplayLinkRef g_display_link  = NULL;
static uint32_t         g_overlay_seed  = 0;
static bool             g_overlay_active = false;
static NSWindow*        g_overlay_window = nil;
static CAShapeLayer*    g_overlay_mask   = nil;    // exclusion-zone mask

// ── attach(nativeHandle, surfaceId, x, y, w, h) ─────────────────────────
// Opens the IOSurface by ID and stores the reference for pixel readback.
// nativeHandle and coordinates are accepted for API compatibility but
// no longer used (no CALayer to position).
static Napi::Value Attach(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 2) {
        Napi::Error::New(env, "attach: expected at least 2 arguments")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }

    uint32_t sid = info[1].As<Napi::Number>().Uint32Value();
    IOSurfaceRef surface = IOSurfaceLookup(sid);
    if (!surface) {
        Napi::Error::New(env, "attach: IOSurfaceLookup failed — invalid surface id")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }

    if (g_surface) CFRelease(g_surface);
    g_surface = surface;

    return env.Undefined();
}

// ── updateFrame(x, y, w, h) ─────────────────────────────────────────────
// No-op: no CALayer to reposition.  Kept for API compatibility.
static Napi::Value UpdateFrame(const Napi::CallbackInfo& info) {
    return info.Env().Undefined();
}

// ── updateSurface(surfaceId) ─────────────────────────────────────────────
// Called when the engine re-creates the IOSurface (e.g. on viewport resize).
static Napi::Value UpdateSurface(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1) return env.Undefined();

    uint32_t sid = info[0].As<Napi::Number>().Uint32Value();
    IOSurfaceRef surface = IOSurfaceLookup(sid);
    if (!surface) {
        Napi::Error::New(env, "updateSurface: IOSurfaceLookup failed")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }

    if (g_surface) CFRelease(g_surface);
    g_surface = surface;
    // If the overlay is active, update its contents to the new IOSurface.
    if (g_overlay_layer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g_overlay_layer.contents = (__bridge id)g_surface;
        [CATransaction commit];
    }
    return env.Undefined();
}

// ── detach() ─────────────────────────────────────────────────────────────
static Napi::Value Detach(const Napi::CallbackInfo& info) {
    if (g_surface) {
        CFRelease(g_surface);
        g_surface = nullptr;
    }
    return info.Env().Undefined();
}

// ── refresh() → { pixels: Buffer, width, height } | undefined ───────────
// Reads BGRA pixel data from the IOSurface and returns it as a Node Buffer.
// The renderer converts BGRA → RGBA and draws to a <canvas>.
static Napi::Value Refresh(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (!g_surface) return env.Undefined();

    size_t width  = IOSurfaceGetWidth(g_surface);
    size_t height = IOSurfaceGetHeight(g_surface);
    if (width == 0 || height == 0) return env.Undefined();

    size_t bytesPerRow = IOSurfaceGetBytesPerRow(g_surface);
    size_t rowBytes    = width * 4;
    size_t dataSize    = width * height * 4;

    // Lock the surface for CPU read access (synchronises with GPU).
    kern_return_t kr = IOSurfaceLock(g_surface, kIOSurfaceLockReadOnly, nullptr);
    if (kr != kIOReturnSuccess) return env.Undefined();

    void* base = IOSurfaceGetBaseAddress(g_surface);
    auto buf = Napi::Buffer<uint8_t>::New(env, dataSize);
    uint8_t* dst = buf.Data();
    const uint8_t* src = static_cast<const uint8_t*>(base);

    // Copy row by row in case bytesPerRow != width * 4 (padding).
    if (bytesPerRow == rowBytes) {
        std::memcpy(dst, src, dataSize);
    } else {
        for (size_t y = 0; y < height; y++) {
            std::memcpy(dst + y * rowBytes, src + y * bytesPerRow, rowBytes);
        }
    }

    IOSurfaceUnlock(g_surface, kIOSurfaceLockReadOnly, nullptr);

    Napi::Object result = Napi::Object::New(env);
    result.Set("pixels", buf);
    result.Set("width",  Napi::Number::New(env, static_cast<double>(width)));
    result.Set("height", Napi::Number::New(env, static_cast<double>(height)));
    return result;
}

// ── setSharedBuffer(sab: SharedArrayBuffer) ──────────────────────────────
// Stores a pointer to the SAB's backing store so refreshShared() can write
// directly into shared memory visible to the renderer process.
static Napi::Value SetSharedBuffer(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    // Accept either ArrayBuffer or SharedArrayBuffer.
    // In N-API, SharedArrayBuffer is NOT an ArrayBuffer — we must extract the
    // backing store from a TypedArray view if the raw value isn't an ArrayBuffer.
    uint8_t* data = nullptr;
    size_t   size = 0;

    if (info.Length() >= 1 && info[0].IsArrayBuffer()) {
        auto ab = info[0].As<Napi::ArrayBuffer>();
        data = static_cast<uint8_t*>(ab.Data());
        size = ab.ByteLength();
    } else if (info.Length() >= 1 && info[0].IsTypedArray()) {
        auto ta = info[0].As<Napi::TypedArray>();
        auto ab = ta.ArrayBuffer();
        data = static_cast<uint8_t*>(ab.Data());
        size = ab.ByteLength();
    } else {
        // Try napi_get_arraybuffer_info directly — works for SharedArrayBuffer
        // in some Node.js versions.
        napi_value val = info[0];
        void* rawData = nullptr;
        size_t rawLen = 0;
        napi_status st = napi_get_arraybuffer_info(env, val, &rawData, &rawLen);
        if (st == napi_ok && rawData && rawLen > 0) {
            data = static_cast<uint8_t*>(rawData);
            size = rawLen;
        } else {
            Napi::Error::New(env, "setSharedBuffer: expected SharedArrayBuffer or ArrayBuffer")
                .ThrowAsJavaScriptException();
            return env.Undefined();
        }
    }

    g_sab_data = data;
    g_sab_size = size;
    g_sab_generation = 0;
    g_write_index = 0;
    return env.Undefined();
}

// ── refreshShared() → boolean ────────────────────────────────────────────
// Reads IOSurface pixels into the pre-registered SharedArrayBuffer.
// Uses double-buffering (ping-pong) so the renderer process can safely read
// from one buffer while we write to the other.
//
// SAB layout (double-buffered):
//   [0]  width  (u32)
//   [4]  height (u32)
//   [8]  generation (u32, atomic — release)
//   [12] readIndex  (u32 — which buffer the renderer should read, 0 or 1)
//   [16]                    buffer 0  (maxPixelBytes)
//   [16 + maxPixelBytes]    buffer 1  (maxPixelBytes)
//
// Returns true if a new frame was written, false otherwise.
static Napi::Value RefreshShared(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (!g_surface || !g_sab_data) return Napi::Boolean::New(env, false);

    // Seed check: skip copy if the staging IOSurface hasn't been updated.
    // The engine bumps the seed (via write-lock/unlock) after each GPU blit.
    uint32_t seed = IOSurfaceGetSeed(g_surface);
    if (seed == g_last_seed) return Napi::Boolean::New(env, false);

    size_t width  = IOSurfaceGetWidth(g_surface);
    size_t height = IOSurfaceGetHeight(g_surface);
    if (width == 0 || height == 0) return Napi::Boolean::New(env, false);

    size_t bytesPerRow = IOSurfaceGetBytesPerRow(g_surface);
    size_t rowBytes    = width * 4;
    size_t dataSize    = width * height * 4;

    // Each half of the pixel region is one ping-pong buffer.
    size_t maxPixelBytes = (g_sab_size - SAB_HEADER_BYTES) / 2;
    if (dataSize > maxPixelBytes) return Napi::Boolean::New(env, false);

    kern_return_t kr = IOSurfaceLock(g_surface, kIOSurfaceLockReadOnly, nullptr);
    if (kr != kIOReturnSuccess) return Napi::Boolean::New(env, false);

    void* base = IOSurfaceGetBaseAddress(g_surface);
    // Write into the current write-side buffer.
    uint8_t* dst = g_sab_data + SAB_HEADER_BYTES + g_write_index * maxPixelBytes;
    const uint8_t* src = static_cast<const uint8_t*>(base);

    if (bytesPerRow == rowBytes) {
        std::memcpy(dst, src, dataSize);
    } else {
        for (size_t y = 0; y < height; y++) {
            std::memcpy(dst + y * rowBytes, src + y * bytesPerRow, rowBytes);
        }
    }

    IOSurfaceUnlock(g_surface, kIOSurfaceLockReadOnly, nullptr);

    // Record seed so next poll skips if no new frame.
    g_last_seed = seed;

    // Publish: write width, height, readIndex, THEN generation (release).
    auto* header = reinterpret_cast<uint32_t*>(g_sab_data);
    header[0] = static_cast<uint32_t>(width);
    header[1] = static_cast<uint32_t>(height);
    header[3] = g_write_index;  // tell renderer which buffer to read
    ++g_sab_generation;
    __atomic_store_n(&header[2], g_sab_generation, __ATOMIC_RELEASE);

    // Flip for next frame.
    g_write_index = 1 - g_write_index;

    return Napi::Boolean::New(env, true);
}

// ── Module init ──────────────────────────────────────────────────────────

// ══════════════════════════════════════════════════════════════════════════
// ── Native Overlay: child NSWindow with IOSurface CALayer (zero-copy) ────
// ══════════════════════════════════════════════════════════════════════════
//
// ── Debug helper: dump CALayer tree ──────────────────────────────────────
static void DumpLayerTree(CALayer* layer, int depth) {
    NSString* indent = [@"" stringByPaddingToLength:depth*2 withString:@" " startingAtIndex:0];
    CGRect f = layer.frame;
    fprintf(stderr, "%s[%s] opaque=%d frame=(%.0f,%.0f,%.0f,%.0f) bg=%s contents=%s\n",
            [indent UTF8String],
            [NSStringFromClass(layer.class) UTF8String],
            (int)layer.opaque,
            f.origin.x, f.origin.y, f.size.width, f.size.height,
            layer.backgroundColor ? [[CIColor colorWithCGColor:layer.backgroundColor].stringRepresentation UTF8String] : "nil",
            layer.contents ? [[NSString stringWithFormat:@"%@", layer.contents] UTF8String] : "nil");
    for (CALayer* sub in layer.sublayers) {
        DumpLayerTree(sub, depth + 1);
    }
}

// Chromium's internal renderer creates an opaque CALayer for the web content,
// so inserting a sublayer underneath doesn't work (it's always occluded).
//
// Instead, we create a separate borderless NSWindow that displays the
// IOSurface via its contentView's layer.  This child window is attached to
// the Electron BrowserWindow via addChildWindow:ordered:NSWindowBelow.
// The Electron window has `transparent: true`, so CSS areas with transparent
// backgrounds let the child window show through.
//
// A CVDisplayLink polls IOSurfaceGetSeed() at the monitor's native refresh
// rate and re-assigns layer.contents when a new frame is available.

// CVDisplayLink callback — runs on a dedicated high-priority thread at VSync.
static CVReturn OverlayDisplayLinkCallback(
    CVDisplayLinkRef       /* displayLink */,
    const CVTimeStamp*     /* inNow */,
    const CVTimeStamp*     /* inOutputTime */,
    CVOptionFlags          /* flagsIn */,
    CVOptionFlags*         /* flagsOut */,
    void*                  /* ctx */)
{
    if (!g_overlay_layer || !g_surface) return kCVReturnSuccess;

    uint32_t seed = IOSurfaceGetSeed(g_surface);
    if (seed == g_overlay_seed) return kCVReturnSuccess;
    g_overlay_seed = seed;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_overlay_layer || !g_surface) return;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g_overlay_layer.contents = (__bridge id)g_surface;
        [CATransaction commit];
    });

    return kCVReturnSuccess;
}

// ── createOverlay(nativeWindowHandle: Buffer) ────────────────────────────
static Napi::Value CreateOverlay(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1) {
        Napi::Error::New(env, "createOverlay: expected nativeWindowHandle")
            .ThrowAsJavaScriptException();
        return Napi::Boolean::New(env, false);
    }

    auto buf = info[0].As<Napi::Buffer<uint8_t>>();
    if (buf.Length() < sizeof(void*)) {
        Napi::Error::New(env, "createOverlay: handle buffer too small")
            .ThrowAsJavaScriptException();
        return Napi::Boolean::New(env, false);
    }

    void* ptr = *reinterpret_cast<void**>(buf.Data());
    id obj = (__bridge id)ptr;

    NSView* contentView = nil;
    if ([obj isKindOfClass:[NSWindow class]]) {
        contentView = [(NSWindow*)obj contentView];
    } else if ([obj isKindOfClass:[NSView class]]) {
        contentView = (NSView*)obj;
    } else {
        Napi::Error::New(env, "createOverlay: handle is not NSWindow or NSView")
            .ThrowAsJavaScriptException();
        return Napi::Boolean::New(env, false);
    }

    NSWindow* parentWindow = [contentView window];
    if (!parentWindow) {
        Napi::Error::New(env, "createOverlay: contentView has no window")
            .ThrowAsJavaScriptException();
        return Napi::Boolean::New(env, false);
    }

    // Tear down previous overlay.
    if (g_overlay_window) {
        [parentWindow removeChildWindow:g_overlay_window];
        [g_overlay_window close];
        g_overlay_window = nil;
    }
    if (g_display_link) {
        CVDisplayLinkStop(g_display_link);
        CVDisplayLinkRelease(g_display_link);
        g_display_link = NULL;
    }

    // Create a borderless child window for the IOSurface.
    // The overlay is ordered BELOW the Electron window.  The viewport area in
    // Chromium has transparent CSS backgrounds, and we clear the root
    // NSViewBackingLayer's backgroundColor so the child window shows through.
    // HTML overlays (ViewCube, metrics, buttons) render on top naturally since
    // they're part of the Electron window which sits above.
    NSRect initialFrame = NSMakeRect(0, 0, 100, 100); // will be repositioned
    g_overlay_window = [[NSWindow alloc]
        initWithContentRect:initialFrame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [g_overlay_window setOpaque:NO];   // allow per-pixel alpha for mask holes
    [g_overlay_window setBackgroundColor:[NSColor clearColor]];
    [g_overlay_window setHasShadow:NO];
    [g_overlay_window setIgnoresMouseEvents:YES]; // clicks pass through to Electron
    [g_overlay_window setLevel:NSNormalWindowLevel];
    [g_overlay_window setReleasedWhenClosed:NO];

    // Set up the content view's layer with IOSurface.
    NSView* overlayContentView = [g_overlay_window contentView];
    [overlayContentView setWantsLayer:YES];

    g_overlay_layer = overlayContentView.layer;
    g_overlay_layer.contentsGravity = kCAGravityResize;
    g_overlay_layer.contentsScale = parentWindow.backingScaleFactor;
    g_overlay_layer.actions = @{
        @"contents": [NSNull null],
        @"bounds":   [NSNull null],
        @"position": [NSNull null],
        @"frame":    [NSNull null],
    };

    if (g_surface) {
        g_overlay_layer.contents = (__bridge id)g_surface;
    }

    // Attach as child window ordered ABOVE the parent Electron window.
    // The 3D scene is directly visible.  A CAShapeLayer mask will punch
    // transparent holes where HTML overlay elements (ViewCube, metrics)
    // need to show through from the Electron window below.
    [parentWindow addChildWindow:g_overlay_window ordered:NSWindowAbove];

    // Set up the mask layer for exclusion zones.  Initially shows everything.
    g_overlay_mask = [CAShapeLayer layer];
    g_overlay_mask.fillRule = kCAFillRuleEvenOdd;
    g_overlay_mask.fillColor = [NSColor whiteColor].CGColor;
    g_overlay_mask.frame = g_overlay_layer.bounds;
    g_overlay_layer.mask = g_overlay_mask;

    g_host_view = contentView;
    g_overlay_active = true;
    g_overlay_seed = 0;

    fprintf(stderr, "[overlay] Child window created. parent=%p overlay=%p surface=%p\n",
            (void*)parentWindow, (void*)g_overlay_window, (void*)g_surface);
    fprintf(stderr, "[overlay] parent.opaque=%d parent.backgroundColor=%s\n",
            (int)parentWindow.opaque,
            [parentWindow.backgroundColor.description UTF8String]);
    // Dump the full layer tree of the Electron window's contentView.
    fprintf(stderr, "[overlay] === Layer tree of parent contentView ===\n");
    DumpLayerTree(contentView.layer, 0);
    fprintf(stderr, "[overlay] === End layer tree ===\n");

    // Start CVDisplayLink.
    CVReturn cvr = CVDisplayLinkCreateWithActiveCGDisplays(&g_display_link);
    if (cvr == kCVReturnSuccess) {
        CVDisplayLinkSetOutputCallback(g_display_link, OverlayDisplayLinkCallback, nullptr);
        CVDisplayLinkStart(g_display_link);
    }

    return Napi::Boolean::New(env, true);
}

// ── updateOverlayBounds(x, y, w, h) ─────────────────────────────────────
// Args are CSS points, origin top-left relative to the Electron window content.
// We convert to screen coordinates for the child window.
static Napi::Value UpdateOverlayBounds(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (!g_overlay_window || !g_host_view || info.Length() < 4) {
        return env.Undefined();
    }

    double x = info[0].As<Napi::Number>().DoubleValue();
    double y = info[1].As<Napi::Number>().DoubleValue();
    double w = info[2].As<Napi::Number>().DoubleValue();
    double h = info[3].As<Napi::Number>().DoubleValue();

    NSWindow* parentWindow = [g_host_view window];
    if (!parentWindow) return env.Undefined();

    // Convert from CSS (top-left origin) to window coords (bottom-left origin).
    NSRect contentRect = [parentWindow contentLayoutRect];
    CGFloat windowContentH = contentRect.size.height;

    // The CSS y is relative to the top of the web content area.
    // Window content coordinates have origin at bottom-left.
    NSRect overlayInWindow = NSMakeRect(
        (CGFloat)x,
        windowContentH - (CGFloat)y - (CGFloat)h,
        (CGFloat)w,
        (CGFloat)h
    );

    // Convert window-relative rect to screen coordinates.
    NSRect screenRect = [parentWindow convertRectToScreen:overlayInWindow];

    [g_overlay_window setFrame:screenRect display:YES animate:NO];

    return env.Undefined();
}

// ── destroyOverlay() ─────────────────────────────────────────────────────
static Napi::Value DestroyOverlay(const Napi::CallbackInfo& info) {
    if (g_display_link) {
        CVDisplayLinkStop(g_display_link);
        CVDisplayLinkRelease(g_display_link);
        g_display_link = NULL;
    }
    if (g_overlay_window) {
        NSWindow* parent = [g_host_view window];
        if (parent) {
            [parent removeChildWindow:g_overlay_window];
        }
        [g_overlay_window close];
        g_overlay_window = nil;
    }
    g_overlay_layer = nil;
    g_overlay_mask  = nil;
    g_host_view = nil;
    g_overlay_active = false;
    return info.Env().Undefined();
}

// ── updateOverlayExclusions(rects: number[][]) ───────────────────────────
// Each rect is [x, y, w, h] in CSS points relative to the overlay window's
// top-left corner (i.e. relative to the viewport div's top-left).
// These areas become transparent so the HTML underneath shows through.
static Napi::Value UpdateOverlayExclusions(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (!g_overlay_mask || !g_overlay_window) return env.Undefined();

    // Use the overlay window's frame in screen-space points to compute size.
    NSRect winFrame = [g_overlay_window frame];
    CGFloat w = winFrame.size.width;
    CGFloat h = winFrame.size.height;

    fprintf(stderr, "[overlay] exclusions: window=%.0fx%.0f nRects=%d\n",
            w, h, info.Length() >= 1 && info[0].IsArray() ? (int)info[0].As<Napi::Array>().Length() : 0);

    // Start with the full rect (everything visible).
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, CGRectMake(0, 0, w, h));

    // Punch holes for each exclusion rect.
    if (info.Length() >= 1 && info[0].IsArray()) {
        Napi::Array arr = info[0].As<Napi::Array>();
        for (uint32_t i = 0; i < arr.Length(); i++) {
            Napi::Value v = arr[i];
            if (!v.IsArray()) continue;
            Napi::Array r = v.As<Napi::Array>();
            if (r.Length() < 4) continue;
            double rx = r.Get((uint32_t)0).As<Napi::Number>().DoubleValue();
            double ry = r.Get((uint32_t)1).As<Napi::Number>().DoubleValue();
            double rw = r.Get((uint32_t)2).As<Napi::Number>().DoubleValue();
            double rh = r.Get((uint32_t)3).As<Napi::Number>().DoubleValue();
            // CALayer coordinate system: origin at bottom-left.
            // CSS coordinate system: origin at top-left. Flip Y.
            CGFloat lx = (CGFloat)rx;
            CGFloat ly = h - (CGFloat)ry - (CGFloat)rh;
            fprintf(stderr, "[overlay]   hole[%u]: css=(%.1f,%.1f,%.1f,%.1f) layer=(%.1f,%.1f)\n",
                    i, rx, ry, rw, rh, lx, ly);
            CGPathAddRect(path, NULL, CGRectMake(lx, ly, (CGFloat)rw, (CGFloat)rh));
        }
    }

    // Apply the mask; size it to match the overlay window's point dimensions.
    g_overlay_mask.frame = CGRectMake(0, 0, w, h);
    g_overlay_mask.path = path;
    CGPathRelease(path);

    fprintf(stderr, "[overlay] mask.frame=(%.0f,%.0f,%.0f,%.0f) layer.bounds=(%.0f,%.0f,%.0f,%.0f)\n",
            g_overlay_mask.frame.origin.x, g_overlay_mask.frame.origin.y,
            g_overlay_mask.frame.size.width, g_overlay_mask.frame.size.height,
            g_overlay_layer.bounds.origin.x, g_overlay_layer.bounds.origin.y,
            g_overlay_layer.bounds.size.width, g_overlay_layer.bounds.size.height);

    return env.Undefined();
}

// ── isOverlayActive() → boolean ──────────────────────────────────────────
static Napi::Value IsOverlayActive(const Napi::CallbackInfo& info) {
    return Napi::Boolean::New(info.Env(), g_overlay_active);
}

// ══════════════════════════════════════════════════════════════════════════
static Napi::Object Init(Napi::Env env, Napi::Object exports) {
    // Legacy / SAB pixel readback
    exports.Set("attach",          Napi::Function::New(env, Attach));
    exports.Set("updateFrame",     Napi::Function::New(env, UpdateFrame));
    exports.Set("updateSurface",   Napi::Function::New(env, UpdateSurface));
    exports.Set("detach",          Napi::Function::New(env, Detach));
    exports.Set("refresh",         Napi::Function::New(env, Refresh));
    exports.Set("setSharedBuffer", Napi::Function::New(env, SetSharedBuffer));
    exports.Set("refreshShared",   Napi::Function::New(env, RefreshShared));
    // Native overlay (zero-copy)
    exports.Set("createOverlay",           Napi::Function::New(env, CreateOverlay));
    exports.Set("updateOverlayBounds",     Napi::Function::New(env, UpdateOverlayBounds));
    exports.Set("updateOverlayExclusions", Napi::Function::New(env, UpdateOverlayExclusions));
    exports.Set("destroyOverlay",          Napi::Function::New(env, DestroyOverlay));
    exports.Set("isOverlayActive",         Napi::Function::New(env, IsOverlayActive));
    return exports;
}

NODE_API_MODULE(iosurface_view, Init)
