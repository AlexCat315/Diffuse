#ifndef WGPU_BRIDGE_H
#define WGPU_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WGPUInstanceImpl* WGPUInstance;
typedef struct WGPUAdapterImpl* WGPUAdapter;
typedef struct WGPUDeviceImpl* WGPUDevice;
typedef struct WGPUQueueImpl* WGPUQueue;

typedef struct WGPUInstanceDescriptor {
    const void* nextInChain;
} WGPUInstanceDescriptor;

int wgpu_bridge_initialize(const char* library_path);
int wgpu_bridge_create_instance(void** out_instance);
int wgpu_bridge_request_adapter(void* instance, void** out_adapter);
int wgpu_bridge_request_device(void* adapter, void** out_device);
int wgpu_bridge_get_queue(void* device, void** out_queue);
int wgpu_bridge_release_queue(void* queue);
int wgpu_bridge_release_device(void* device);
int wgpu_bridge_release_adapter(void* adapter);
int wgpu_bridge_release_instance(void* instance);
void wgpu_bridge_shutdown(void);
const char* wgpu_bridge_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
