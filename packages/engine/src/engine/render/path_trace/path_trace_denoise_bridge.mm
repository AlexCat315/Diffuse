#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <vector>

static MTLStorageMode guava_host_visible_texture_storage_mode(id<MTLDevice> device) {
    if (@available(macOS 10.15, *)) {
        return device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
    }
    return MTLStorageModeManaged;
}

static id<MTLTexture> guava_make_rgba32f_texture(
    id<MTLDevice> device,
    uint32_t width,
    uint32_t height,
    MTLTextureUsage usage,
    MTLStorageMode storage_mode,
    const float* rgba_pixels
) {
    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat: MTLPixelFormatRGBA32Float
                                                                                     width: width
                                                                                    height: height
                                                                                 mipmapped: NO];
    desc.usage = usage;
    desc.storageMode = storage_mode;
    id<MTLTexture> texture = [device newTextureWithDescriptor: desc];
    if (!texture) return nil;

    if (rgba_pixels) {
        const NSUInteger bytes_per_row = (NSUInteger)width * sizeof(float) * 4;
        [texture replaceRegion: MTLRegionMake2D(0, 0, width, height)
                   mipmapLevel: 0
                     withBytes: rgba_pixels
                   bytesPerRow: bytes_per_row];
    }
    return texture;
}

extern "C" bool guava_path_trace_mps_guided_denoise(
    const float* beauty_rgb,
    const float* guidance_rgb,
    uint32_t width,
    uint32_t height,
    float* out_rgb
) {
    if (!beauty_rgb || !guidance_rgb || !out_rgb || width == 0 || height == 0) return false;

    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device || !MPSSupportsMTLDevice(device)) return false;

        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!queue) return false;

        const size_t pixel_count = (size_t)width * (size_t)height;
        std::vector<float> beauty_rgba(pixel_count * 4, 1.0f);
        std::vector<float> guidance_rgba(pixel_count * 4, 1.0f);
        for (size_t i = 0; i < pixel_count; ++i) {
            const size_t src = i * 3;
            const size_t dst = i * 4;
            beauty_rgba[dst + 0] = beauty_rgb[src + 0];
            beauty_rgba[dst + 1] = beauty_rgb[src + 1];
            beauty_rgba[dst + 2] = beauty_rgb[src + 2];
            guidance_rgba[dst + 0] = guidance_rgb[src + 0];
            guidance_rgba[dst + 1] = guidance_rgb[src + 1];
            guidance_rgba[dst + 2] = guidance_rgb[src + 2];
        }

        const MTLStorageMode storage_mode = guava_host_visible_texture_storage_mode(device);
        const MTLTextureUsage rw_usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> source_texture = guava_make_rgba32f_texture(device, width, height, rw_usage, storage_mode, beauty_rgba.data());
        id<MTLTexture> guidance_texture = guava_make_rgba32f_texture(device, width, height, rw_usage, storage_mode, guidance_rgba.data());
        id<MTLTexture> coeff_a_texture = guava_make_rgba32f_texture(device, width, height, rw_usage, storage_mode, nullptr);
        id<MTLTexture> coeff_b_texture = guava_make_rgba32f_texture(device, width, height, rw_usage, storage_mode, nullptr);
        id<MTLTexture> output_texture = guava_make_rgba32f_texture(device, width, height, rw_usage, storage_mode, nullptr);
        if (!source_texture || !guidance_texture || !coeff_a_texture || !coeff_b_texture || !output_texture) return false;

        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
        if (!command_buffer) return false;

        MPSImageGuidedFilter* filter = [[MPSImageGuidedFilter alloc] initWithDevice: device kernelDiameter: 7];
        if (!filter) return false;
        filter.epsilon = 0.00035f;
        filter.reconstructScale = 1.0f;
        filter.reconstructOffset = 0.0f;

        [filter encodeRegressionToCommandBuffer: command_buffer
                                   sourceTexture: source_texture
                                 guidanceTexture: guidance_texture
                                  weightsTexture: nil
                         destinationCoefficientsTextureA: coeff_a_texture
                         destinationCoefficientsTextureB: coeff_b_texture];
        [filter encodeReconstructionToCommandBuffer: command_buffer
                                     guidanceTexture: guidance_texture
                                coefficientsTextureA: coeff_a_texture
                                coefficientsTextureB: coeff_b_texture
                                  destinationTexture: output_texture];

        if (storage_mode == MTLStorageModeManaged) {
            id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
            if (!blit) return false;
            [blit synchronizeTexture: output_texture slice: 0 level: 0];
            [blit endEncoding];
        }

        [command_buffer commit];
        [command_buffer waitUntilCompleted];
        if (command_buffer.status != MTLCommandBufferStatusCompleted) return false;

        std::vector<float> output_rgba(pixel_count * 4, 0.0f);
        const NSUInteger bytes_per_row = (NSUInteger)width * sizeof(float) * 4;
        [output_texture getBytes: output_rgba.data()
                     bytesPerRow: bytes_per_row
                      fromRegion: MTLRegionMake2D(0, 0, width, height)
                     mipmapLevel: 0];

        for (size_t i = 0; i < pixel_count; ++i) {
            const size_t src = i * 4;
            const size_t dst = i * 3;
            out_rgb[dst + 0] = output_rgba[src + 0];
            out_rgb[dst + 1] = output_rgba[src + 1];
            out_rgb[dst + 2] = output_rgba[src + 2];
        }

        return true;
    }
}
