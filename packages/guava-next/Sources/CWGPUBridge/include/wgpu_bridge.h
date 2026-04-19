#ifndef WGPU_BRIDGE_H
#define WGPU_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WGPUInstanceImpl* WGPUInstance;

typedef struct WGPUInstanceDescriptor {
    const void* nextInChain;
} WGPUInstanceDescriptor;

int wgpu_bridge_initialize(const char* library_path);
int wgpu_bridge_create_instance(void** out_instance);
int wgpu_bridge_release_instance(void* instance);
void wgpu_bridge_shutdown(void);
const char* wgpu_bridge_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
