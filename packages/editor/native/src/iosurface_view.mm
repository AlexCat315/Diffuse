// IOSurface pixel readback addon for macOS.
// Instead of attaching a CALayer (which conflicts with Chromium's layer
// compositing and prevents DOM overlays), we read IOSurface pixel data and
// return it as a Buffer — the renderer then draws it on a <canvas> element
// just like the Linux shm path.
//
// Two modes of operation:
//  A) Legacy (IPC-based): refresh() → allocates Buffer, returns pixels + dims
//  B) SharedArrayBuffer: setSharedBuffer(sab) then refreshShared() → writes
//     pixels directly into the SAB; renderer polls via Atomics, zero IPC.
//
// SAB layout (all uint32 at 4-byte offsets):
//   [0]  width
//   [4]  height
//   [8]  generation (monotonic counter, use Atomics)
//   [12] readIndex  (0 or 1 — which ping-pong buffer to read)
//   [16] buffer 0: BGRA pixel data  (maxPixelBytes)
//   [16 + maxPixelBytes] buffer 1: BGRA pixel data  (maxPixelBytes)

#import <IOSurface/IOSurface.h>
#include <napi.h>
#include <cstring>
#include <atomic>

static IOSurfaceRef g_surface = nullptr;

// ── SharedArrayBuffer state ──────────────────────────────────────────────
static uint8_t* g_sab_data = nullptr;   // pointer into SAB backing store
static size_t   g_sab_size = 0;         // total SAB size in bytes
static uint32_t g_sab_generation = 0;   // monotonic frame counter
static uint32_t g_write_index   = 0;    // ping-pong buffer index (0 or 1)
static constexpr size_t SAB_HEADER_BYTES = 16;

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
static Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set("attach",          Napi::Function::New(env, Attach));
    exports.Set("updateFrame",     Napi::Function::New(env, UpdateFrame));
    exports.Set("updateSurface",   Napi::Function::New(env, UpdateSurface));
    exports.Set("detach",          Napi::Function::New(env, Detach));
    exports.Set("refresh",         Napi::Function::New(env, Refresh));
    exports.Set("setSharedBuffer", Napi::Function::New(env, SetSharedBuffer));
    exports.Set("refreshShared",   Napi::Function::New(env, RefreshShared));
    return exports;
}

NODE_API_MODULE(iosurface_view, Init)
