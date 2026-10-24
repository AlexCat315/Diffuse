#include "decode.h"

// Reuse the decoder already vendored by the SDK without linking the engine,
// its renderer, or platform-specific frameworks into the developer tools.
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

unsigned char *guava_tool_decode_image(const unsigned char *data, int count, int *width, int *height) {
    return stbi_load_from_memory(data, count, width, height, NULL, 4);
}

void guava_tool_free_image(unsigned char *pixels) {
    stbi_image_free(pixels);
}
