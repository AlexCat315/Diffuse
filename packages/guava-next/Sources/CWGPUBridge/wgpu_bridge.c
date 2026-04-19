#include "wgpu_bridge.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef WGPUInstance (*PFN_wgpuCreateInstance)(const WGPUInstanceDescriptor*);
typedef void (*PFN_wgpuInstanceRelease)(WGPUInstance);

static void* g_wgpu_lib = NULL;
static PFN_wgpuCreateInstance g_create_instance = NULL;
static PFN_wgpuInstanceRelease g_release_instance = NULL;
static char g_last_error[256] = {0};

static void set_error(const char* msg) {
    if (msg == NULL) {
        g_last_error[0] = '\0';
        return;
    }
    strncpy(g_last_error, msg, sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
}

const char* wgpu_bridge_last_error(void) {
    return g_last_error;
}

int wgpu_bridge_initialize(const char* library_path) {
    if (g_wgpu_lib != NULL) {
        return 1;
    }

    const char* path = library_path;
    if (path == NULL || path[0] == '\0') {
#if defined(__APPLE__)
        path = "libwgpu_native.dylib";
#elif defined(_WIN32)
        path = "wgpu_native.dll";
#else
        path = "libwgpu_native.so";
#endif
    }

    g_wgpu_lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (g_wgpu_lib == NULL) {
        set_error(dlerror());
        return 0;
    }

    g_create_instance = (PFN_wgpuCreateInstance)dlsym(g_wgpu_lib, "wgpuCreateInstance");
    g_release_instance = (PFN_wgpuInstanceRelease)dlsym(g_wgpu_lib, "wgpuInstanceRelease");

    if (g_create_instance == NULL || g_release_instance == NULL) {
        set_error("Failed to load required wgpu symbols");
        dlclose(g_wgpu_lib);
        g_wgpu_lib = NULL;
        g_create_instance = NULL;
        g_release_instance = NULL;
        return 0;
    }

    set_error(NULL);
    return 1;
}

int wgpu_bridge_create_instance(void** out_instance) {
    if (out_instance == NULL) {
        set_error("out_instance is null");
        return 0;
    }
    *out_instance = NULL;

    if (g_create_instance == NULL) {
        set_error("Bridge not initialized");
        return 0;
    }

    WGPUInstanceDescriptor desc;
    desc.nextInChain = NULL;

    WGPUInstance instance = g_create_instance(&desc);
    if (instance == NULL) {
        set_error("wgpuCreateInstance returned null");
        return 0;
    }

    *out_instance = (void*)instance;
    return 1;
}

int wgpu_bridge_release_instance(void* instance) {
    if (instance == NULL) {
        return 1;
    }

    if (g_release_instance == NULL) {
        set_error("Bridge not initialized");
        return 0;
    }

    g_release_instance((WGPUInstance)instance);
    return 1;
}

void wgpu_bridge_shutdown(void) {
    g_create_instance = NULL;
    g_release_instance = NULL;

    if (g_wgpu_lib != NULL) {
        dlclose(g_wgpu_lib);
        g_wgpu_lib = NULL;
    }

    set_error(NULL);
}
