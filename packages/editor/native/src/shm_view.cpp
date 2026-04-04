// shm_view.cpp — Linux N-API addon for cross-process viewport display via
// POSIX shared memory.  The engine renders to a VkImage, blits pixels into a
// named shm region every frame, and this addon mmaps the same region so
// Electron can read the pixel data.
//
// Exports the same JS API as iosurface_view.mm for platform-transparent usage:
//   attach(nativeHandle, surfaceId, x, y, w, h)
//   updateFrame(x, y, w, h)
//   updateSurface(surfaceId)
//   detach()
//   refresh()   → returns { pixels: Buffer, width, height } or undefined
//   getPixels() → returns { pixels: Buffer, width, height } or undefined

#include <napi.h>
#include <cstring>
#include <cstdio>

#ifdef __linux__
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#endif

namespace {

// State
static char g_shm_name[64] = {};
static int  g_shm_fd = -1;
static void* g_shm_ptr = nullptr;
static size_t g_shm_size = 0;
static uint32_t g_width = 0;
static uint32_t g_height = 0;
static uint32_t g_bpp = 4; // bytes per pixel (BGRA8)

static void cleanup_shm() {
#ifdef __linux__
    if (g_shm_ptr && g_shm_ptr != MAP_FAILED) {
        munmap(g_shm_ptr, g_shm_size);
        g_shm_ptr = nullptr;
    }
    if (g_shm_fd >= 0) {
        close(g_shm_fd);
        g_shm_fd = -1;
    }
    g_shm_size = 0;
#endif
}

static bool open_shm(const char* name, uint32_t width, uint32_t height) {
#ifdef __linux__
    cleanup_shm();

    strncpy(g_shm_name, name, sizeof(g_shm_name) - 1);
    g_shm_name[sizeof(g_shm_name) - 1] = '\0';
    g_width = width;
    g_height = height;
    g_shm_size = (size_t)width * height * g_bpp;

    g_shm_fd = shm_open(name, O_RDONLY, 0);
    if (g_shm_fd < 0) {
        fprintf(stderr, "[shm_view] shm_open(\"%s\") failed\n", name);
        return false;
    }

    g_shm_ptr = mmap(nullptr, g_shm_size, PROT_READ, MAP_SHARED, g_shm_fd, 0);
    if (g_shm_ptr == MAP_FAILED) {
        fprintf(stderr, "[shm_view] mmap failed\n");
        close(g_shm_fd);
        g_shm_fd = -1;
        g_shm_ptr = nullptr;
        return false;
    }
    return true;
#else
    (void)name; (void)width; (void)height;
    return false;
#endif
}

// ── N-API exports ─────────────────────────────────────────────────

// attach(nativeHandle: Buffer, surfaceId: number, x, y, w, h)
// On Linux we ignore nativeHandle / surfaceId / coordinates — the shm name
// is set later via updateSurface which receives the shmName.
Napi::Value Attach(const Napi::CallbackInfo& info) {
    // No-op on Linux (CALayer is macOS-only).  The shm mapping is established
    // when updateSurface is called with shmName + dimensions.
    return info.Env().Undefined();
}

// updateFrame(x, y, w, h) — position/size hint (unused on Linux canvas path)
Napi::Value UpdateFrame(const Napi::CallbackInfo& info) {
    return info.Env().Undefined();
}

// updateSurface(surfaceIdOrZero, shmName?, width?, height?)
// On Linux, surfaceId is 0 and shmName + width + height are used instead.
Napi::Value UpdateSurface(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() >= 4 && info[1].IsString()) {
        std::string name = info[1].As<Napi::String>().Utf8Value();
        uint32_t w = info[2].As<Napi::Number>().Uint32Value();
        uint32_t h = info[3].As<Napi::Number>().Uint32Value();
        open_shm(name.c_str(), w, h);
    }
    return env.Undefined();
}

// detach()
Napi::Value Detach(const Napi::CallbackInfo& info) {
    cleanup_shm();
    return info.Env().Undefined();
}

// refresh() → { pixels: Buffer, width, height } | undefined
// Returns BGRA8 pixel data from shared memory so the renderer can draw it.
Napi::Value Refresh(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
#ifdef __linux__
    if (!g_shm_ptr || g_shm_size == 0) return env.Undefined();

    // Copy pixels into a new Buffer (don't expose the raw mmap to JS GC).
    auto buf = Napi::Buffer<uint8_t>::Copy(env, static_cast<uint8_t*>(g_shm_ptr), g_shm_size);

    Napi::Object result = Napi::Object::New(env);
    result.Set("pixels", buf);
    result.Set("width", Napi::Number::New(env, g_width));
    result.Set("height", Napi::Number::New(env, g_height));
    return result;
#else
    return env.Undefined();
#endif
}

// getPixels() — alias for refresh()
Napi::Value GetPixels(const Napi::CallbackInfo& info) {
    return Refresh(info);
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set("attach", Napi::Function::New(env, Attach));
    exports.Set("updateFrame", Napi::Function::New(env, UpdateFrame));
    exports.Set("updateSurface", Napi::Function::New(env, UpdateSurface));
    exports.Set("detach", Napi::Function::New(env, Detach));
    exports.Set("refresh", Napi::Function::New(env, Refresh));
    exports.Set("getPixels", Napi::Function::New(env, GetPixels));
    return exports;
}

} // namespace

NODE_API_MODULE(iosurface_view, Init)
