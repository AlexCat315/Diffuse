// IOSurface pixel readback addon for macOS.
// Instead of attaching a CALayer (which conflicts with Chromium's layer
// compositing and prevents DOM overlays), we read IOSurface pixel data and
// return it as a Buffer — the renderer then draws it on a <canvas> element
// just like the Linux shm path.
//
// This approach:
//  1) Eliminates all CALayer / DOM z-ordering issues
//  2) Works identically to the Linux shared-memory path
//  3) Naturally supports DOM overlays (ViewCube, shading bar)
//  4) Enables future remote rendering (swap pixel source for WebRTC)

#import <IOSurface/IOSurface.h>
#include <napi.h>
#include <cstring>

static IOSurfaceRef g_surface = nullptr;

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

// ── Module init ──────────────────────────────────────────────────────────
static Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set("attach",        Napi::Function::New(env, Attach));
    exports.Set("updateFrame",   Napi::Function::New(env, UpdateFrame));
    exports.Set("updateSurface", Napi::Function::New(env, UpdateSurface));
    exports.Set("detach",        Napi::Function::New(env, Detach));
    exports.Set("refresh",       Napi::Function::New(env, Refresh));
    return exports;
}

NODE_API_MODULE(iosurface_view, Init)
