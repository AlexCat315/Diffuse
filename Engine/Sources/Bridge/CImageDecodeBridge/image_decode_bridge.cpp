#include "image_decode_bridge.h"

#include <lunasvg.h>
#include <webp/decode.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

namespace {

std::string lower_extension(const char* extension) {
    std::string ext = extension ? extension : "";
    if (!ext.empty() && ext[0] == '.') {
        ext.erase(ext.begin());
    }
    std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return ext;
}

char* copy_message(const char* message) {
    if (message == nullptr) {
        return nullptr;
    }
    const size_t length = std::strlen(message);
    char* copy = static_cast<char*>(std::malloc(length + 1));
    if (copy == nullptr) {
        return nullptr;
    }
    std::memcpy(copy, message, length + 1);
    return copy;
}

bool fail(GuavaImageDecodeResult* result, const char* message) {
    if (result) {
        result->pixels = nullptr;
        result->width = 0;
        result->height = 0;
        result->error_message = copy_message(message);
    }
    return false;
}

bool assign_pixels(std::vector<uint8_t>&& pixels,
                   int width,
                   int height,
                   GuavaImageDecodeResult* result) {
    const size_t byte_count = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
    uint8_t* out = static_cast<uint8_t*>(std::malloc(byte_count));
    if (out == nullptr) {
        return fail(result, "out of memory while copying decoded image");
    }
    std::memcpy(out, pixels.data(), byte_count);
    result->pixels = out;
    result->width = width;
    result->height = height;
    result->error_message = nullptr;
    return true;
}

std::vector<uint8_t> resize_rgba(const uint8_t* src,
                                 int src_width,
                                 int src_height,
                                 int dst_width,
                                 int dst_height) {
    std::vector<uint8_t> dst(static_cast<size_t>(dst_width) * static_cast<size_t>(dst_height) * 4);
    if (src_width == dst_width && src_height == dst_height) {
        std::memcpy(dst.data(), src, dst.size());
        return dst;
    }

    const double scale_x = static_cast<double>(src_width) / static_cast<double>(dst_width);
    const double scale_y = static_cast<double>(src_height) / static_cast<double>(dst_height);
    for (int y = 0; y < dst_height; ++y) {
        const double source_y = (static_cast<double>(y) + 0.5) * scale_y - 0.5;
        const int y0 = std::clamp(static_cast<int>(std::floor(source_y)), 0, src_height - 1);
        const int y1 = std::min(y0 + 1, src_height - 1);
        const double fy = std::clamp(source_y - static_cast<double>(y0), 0.0, 1.0);
        for (int x = 0; x < dst_width; ++x) {
            const double source_x = (static_cast<double>(x) + 0.5) * scale_x - 0.5;
            const int x0 = std::clamp(static_cast<int>(std::floor(source_x)), 0, src_width - 1);
            const int x1 = std::min(x0 + 1, src_width - 1);
            const double fx = std::clamp(source_x - static_cast<double>(x0), 0.0, 1.0);

            const uint8_t* p00 = src + (static_cast<size_t>(y0) * src_width + x0) * 4;
            const uint8_t* p10 = src + (static_cast<size_t>(y0) * src_width + x1) * 4;
            const uint8_t* p01 = src + (static_cast<size_t>(y1) * src_width + x0) * 4;
            const uint8_t* p11 = src + (static_cast<size_t>(y1) * src_width + x1) * 4;
            uint8_t* out = dst.data() + (static_cast<size_t>(y) * dst_width + x) * 4;

            for (int c = 0; c < 4; ++c) {
                const double top = static_cast<double>(p00[c]) * (1.0 - fx) + static_cast<double>(p10[c]) * fx;
                const double bottom = static_cast<double>(p01[c]) * (1.0 - fx) + static_cast<double>(p11[c]) * fx;
                out[c] = static_cast<uint8_t>(std::clamp(std::round(top * (1.0 - fy) + bottom * fy), 0.0, 255.0));
            }
        }
    }
    return dst;
}

bool output_rgba(const uint8_t* pixels,
                 int width,
                 int height,
                 int target_width,
                 int target_height,
                 GuavaImageDecodeResult* result) {
    if (width <= 0 || height <= 0) {
        return fail(result, "decoded image has invalid dimensions");
    }
    const int out_width = target_width > 0 ? target_width : width;
    const int out_height = target_height > 0 ? target_height : height;
    if (out_width <= 0 || out_height <= 0) {
        return fail(result, "target image dimensions are invalid");
    }
    return assign_pixels(resize_rgba(pixels, width, height, out_width, out_height),
                         out_width,
                         out_height,
                         result);
}

bool decode_stb(const uint8_t* data,
                size_t data_size,
                int target_width,
                int target_height,
                GuavaImageDecodeResult* result) {
    int width = 0;
    int height = 0;
    int channels = 0;
    stbi_uc* decoded = stbi_load_from_memory(data,
                                             static_cast<int>(data_size),
                                             &width,
                                             &height,
                                             &channels,
                                             4);
    if (decoded == nullptr) {
        return fail(result, stbi_failure_reason());
    }
    const bool ok = output_rgba(decoded, width, height, target_width, target_height, result);
    stbi_image_free(decoded);
    return ok;
}

bool decode_webp(const uint8_t* data,
                 size_t data_size,
                 int target_width,
                 int target_height,
                 GuavaImageDecodeResult* result) {
    int width = 0;
    int height = 0;
    uint8_t* decoded = WebPDecodeRGBA(data, data_size, &width, &height);
    if (decoded == nullptr) {
        return fail(result, "libwebp failed to decode image");
    }
    const bool ok = output_rgba(decoded, width, height, target_width, target_height, result);
    WebPFree(decoded);
    return ok;
}

bool decode_svg(const uint8_t* data,
                size_t data_size,
                int target_width,
                int target_height,
                GuavaImageDecodeResult* result) {
    auto document = lunasvg::Document::loadFromData(reinterpret_cast<const char*>(data), data_size);
    if (document == nullptr) {
        return fail(result, "lunasvg failed to parse SVG");
    }

    int width = target_width > 0 ? target_width : static_cast<int>(std::ceil(document->width()));
    int height = target_height > 0 ? target_height : static_cast<int>(std::ceil(document->height()));
    if (width <= 0) {
        width = 64;
    }
    if (height <= 0) {
        height = 64;
    }

    auto bitmap = document->renderToBitmap(width, height, 0x00000000);
    if (bitmap.isNull()) {
        return fail(result, "lunasvg failed to rasterize SVG");
    }
    bitmap.convertToRGBA();
    return output_rgba(bitmap.data(), bitmap.width(), bitmap.height(), width, height, result);
}

} // namespace

extern "C" bool guava_image_decode_memory(const uint8_t* data,
                                           size_t data_size,
                                           const char* extension,
                                           int32_t target_width,
                                           int32_t target_height,
                                           GuavaImageDecodeResult* out_result) {
    if (out_result == nullptr) {
        return false;
    }
    out_result->pixels = nullptr;
    out_result->width = 0;
    out_result->height = 0;
    out_result->error_message = nullptr;

    if (data == nullptr || data_size == 0) {
        return fail(out_result, "empty image data");
    }

    const std::string ext = lower_extension(extension);
    if (ext == "png" || ext == "jpg" || ext == "jpeg") {
        return decode_stb(data, data_size, target_width, target_height, out_result);
    }
    if (ext == "webp") {
        return decode_webp(data, data_size, target_width, target_height, out_result);
    }
    if (ext == "svg") {
        return decode_svg(data, data_size, target_width, target_height, out_result);
    }
    return fail(out_result, "unsupported image format");
}

extern "C" void guava_image_decode_free(GuavaImageDecodeResult* result) {
    if (result == nullptr) {
        return;
    }
    std::free(result->pixels);
    std::free(result->error_message);
    result->pixels = nullptr;
    result->error_message = nullptr;
    result->width = 0;
    result->height = 0;
}
