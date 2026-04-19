#include "wgpu_bridge.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

typedef enum WGPURequestAdapterStatus {
    WGPURequestAdapterStatus_Success = 0,
    WGPURequestAdapterStatus_Unavailable = 1,
    WGPURequestAdapterStatus_Error = 2,
    WGPURequestAdapterStatus_Unknown = 3,
} WGPURequestAdapterStatus;

typedef enum WGPURequestDeviceStatus {
    WGPURequestDeviceStatus_Success = 0,
    WGPURequestDeviceStatus_Error = 1,
    WGPURequestDeviceStatus_Unknown = 2,
} WGPURequestDeviceStatus;

typedef struct WGPURequestAdapterOptions {
    const void* nextInChain;
    void* compatibleSurface;
    int powerPreference;
    int forceFallbackAdapter;
} WGPURequestAdapterOptions;

typedef struct WGPUDeviceDescriptor {
    const void* nextInChain;
    const char* label;
} WGPUDeviceDescriptor;

typedef void (*WGPURequestAdapterCallback)(WGPURequestAdapterStatus status, WGPUAdapter adapter, const char* message, void* userdata);
typedef void (*WGPURequestDeviceCallback)(WGPURequestDeviceStatus status, WGPUDevice device, const char* message, void* userdata);

typedef WGPUInstance (*PFN_wgpuCreateInstance)(const WGPUInstanceDescriptor*);
typedef void (*PFN_wgpuInstanceRelease)(WGPUInstance);
typedef void (*PFN_wgpuInstanceRequestAdapter)(WGPUInstance, const WGPURequestAdapterOptions*, WGPURequestAdapterCallback, void*);
typedef void (*PFN_wgpuAdapterRequestDevice)(WGPUAdapter, const WGPUDeviceDescriptor*, WGPURequestDeviceCallback, void*);
typedef void (*PFN_wgpuAdapterRelease)(WGPUAdapter);
typedef void (*PFN_wgpuDeviceRelease)(WGPUDevice);

static void* g_wgpu_lib = NULL;
static PFN_wgpuCreateInstance g_create_instance = NULL;
static PFN_wgpuInstanceRelease g_release_instance = NULL;
static PFN_wgpuInstanceRequestAdapter g_request_adapter = NULL;
static PFN_wgpuAdapterRequestDevice g_request_device = NULL;
static PFN_wgpuAdapterRelease g_release_adapter = NULL;
static PFN_wgpuDeviceRelease g_release_device = NULL;
static char g_last_error[256] = {0};

typedef struct AwaitResult {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int done;
    int success;
    void* object;
    char message[128];
} AwaitResult;

static void set_error(const char* msg) {
    if (msg == NULL) {
        g_last_error[0] = '\0';
        return;
    }
    strncpy(g_last_error, msg, sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
}

static void await_init(AwaitResult* ar) {
    pthread_mutex_init(&ar->mutex, NULL);
    pthread_cond_init(&ar->cond, NULL);
    ar->done = 0;
    ar->success = 0;
    ar->object = NULL;
    ar->message[0] = '\0';
}

static void await_deinit(AwaitResult* ar) {
    pthread_cond_destroy(&ar->cond);
    pthread_mutex_destroy(&ar->mutex);
}

static void await_finish(AwaitResult* ar, int success, void* object, const char* message) {
    pthread_mutex_lock(&ar->mutex);
    ar->done = 1;
    ar->success = success;
    ar->object = object;
    if (message != NULL) {
        strncpy(ar->message, message, sizeof(ar->message) - 1);
        ar->message[sizeof(ar->message) - 1] = '\0';
    }
    pthread_cond_signal(&ar->cond);
    pthread_mutex_unlock(&ar->mutex);
}

static void await_wait(AwaitResult* ar) {
    pthread_mutex_lock(&ar->mutex);
    while (!ar->done) {
        pthread_cond_wait(&ar->cond, &ar->mutex);
    }
    pthread_mutex_unlock(&ar->mutex);
}

static void adapter_callback(WGPURequestAdapterStatus status, WGPUAdapter adapter, const char* message, void* userdata) {
    AwaitResult* ar = (AwaitResult*)userdata;
    const int ok = (status == WGPURequestAdapterStatus_Success && adapter != NULL) ? 1 : 0;
    await_finish(ar, ok, (void*)adapter, message);
}

static void device_callback(WGPURequestDeviceStatus status, WGPUDevice device, const char* message, void* userdata) {
    AwaitResult* ar = (AwaitResult*)userdata;
    const int ok = (status == WGPURequestDeviceStatus_Success && device != NULL) ? 1 : 0;
    await_finish(ar, ok, (void*)device, message);
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
    g_request_adapter = (PFN_wgpuInstanceRequestAdapter)dlsym(g_wgpu_lib, "wgpuInstanceRequestAdapter");
    g_request_device = (PFN_wgpuAdapterRequestDevice)dlsym(g_wgpu_lib, "wgpuAdapterRequestDevice");
    g_release_adapter = (PFN_wgpuAdapterRelease)dlsym(g_wgpu_lib, "wgpuAdapterRelease");
    g_release_device = (PFN_wgpuDeviceRelease)dlsym(g_wgpu_lib, "wgpuDeviceRelease");

    if (g_create_instance == NULL ||
        g_release_instance == NULL ||
        g_request_adapter == NULL ||
        g_request_device == NULL ||
        g_release_adapter == NULL ||
        g_release_device == NULL) {
        set_error("Failed to load required wgpu symbols");
        dlclose(g_wgpu_lib);
        g_wgpu_lib = NULL;
        g_create_instance = NULL;
        g_release_instance = NULL;
        g_request_adapter = NULL;
        g_request_device = NULL;
        g_release_adapter = NULL;
        g_release_device = NULL;
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

int wgpu_bridge_request_adapter(void* instance, void** out_adapter) {
    if (instance == NULL || out_adapter == NULL) {
        set_error("invalid adapter request arguments");
        return 0;
    }
    *out_adapter = NULL;

    if (g_request_adapter == NULL) {
        set_error("Bridge not initialized");
        return 0;
    }

    WGPURequestAdapterOptions options;
    memset(&options, 0, sizeof(options));

    AwaitResult ar;
    await_init(&ar);
    g_request_adapter((WGPUInstance)instance, &options, adapter_callback, &ar);
    await_wait(&ar);

    if (!ar.success) {
        set_error(ar.message[0] != '\0' ? ar.message : "wgpuInstanceRequestAdapter failed");
        await_deinit(&ar);
        return 0;
    }

    *out_adapter = ar.object;
    await_deinit(&ar);
    return 1;
}

int wgpu_bridge_request_device(void* adapter, void** out_device) {
    if (adapter == NULL || out_device == NULL) {
        set_error("invalid device request arguments");
        return 0;
    }
    *out_device = NULL;

    if (g_request_device == NULL) {
        set_error("Bridge not initialized");
        return 0;
    }

    WGPUDeviceDescriptor descriptor;
    memset(&descriptor, 0, sizeof(descriptor));

    AwaitResult ar;
    await_init(&ar);
    g_request_device((WGPUAdapter)adapter, &descriptor, device_callback, &ar);
    await_wait(&ar);

    if (!ar.success) {
        set_error(ar.message[0] != '\0' ? ar.message : "wgpuAdapterRequestDevice failed");
        await_deinit(&ar);
        return 0;
    }

    *out_device = ar.object;
    await_deinit(&ar);
    return 1;
}

int wgpu_bridge_release_device(void* device) {
    if (device == NULL) {
        return 1;
    }
    if (g_release_device == NULL) {
        set_error("Bridge not initialized");
        return 0;
    }
    g_release_device((WGPUDevice)device);
    return 1;
}

int wgpu_bridge_release_adapter(void* adapter) {
    if (adapter == NULL) {
        return 1;
    }
    if (g_release_adapter == NULL) {
        set_error("Bridge not initialized");
        return 0;
    }
    g_release_adapter((WGPUAdapter)adapter);
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
    g_request_adapter = NULL;
    g_request_device = NULL;
    g_release_adapter = NULL;
    g_release_device = NULL;

    if (g_wgpu_lib != NULL) {
        dlclose(g_wgpu_lib);
        g_wgpu_lib = NULL;
    }

    set_error(NULL);
}
