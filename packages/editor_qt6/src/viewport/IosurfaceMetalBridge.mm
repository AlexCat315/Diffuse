#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include "IosurfaceMetalBridge.h"

void *guava_create_metal_texture_from_iosurface(
    void *metalDevice,
    quint32 surfaceId,
    int width,
    int height)
{
    if (!metalDevice || surfaceId == 0 || width <= 0 || height <= 0)
    {
        return nullptr;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)metalDevice;
    IOSurfaceRef ioSurface = IOSurfaceLookup(surfaceId);
    if (!ioSurface)
    {
        return nullptr;
    }

    const size_t surfaceWidth = IOSurfaceGetWidth(ioSurface);
    const size_t surfaceHeight = IOSurfaceGetHeight(ioSurface);
    if (surfaceWidth == 0 || surfaceHeight == 0)
    {
        CFRelease(ioSurface);
        return nullptr;
    }

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:surfaceWidth
                                                                                     height:surfaceHeight
                                                                                  mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    id<MTLTexture> texture = [device newTextureWithDescriptor:desc iosurface:ioSurface plane:0];
    CFRelease(ioSurface);
    if (!texture)
    {
        return nullptr;
    }

    [texture retain];
    return (void *)texture;
}

void guava_release_metal_texture(void *metalTexture)
{
    if (!metalTexture)
    {
        return;
    }

    [(id<MTLTexture>)metalTexture release];
}
