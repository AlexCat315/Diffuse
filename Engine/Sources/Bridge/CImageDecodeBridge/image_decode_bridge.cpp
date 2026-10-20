#include "image_decode_bridge.h"

#include <lunasvg.h>
#include <webp/decode.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <climits>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_BMP
#define STBI_ONLY_GIF
#define STBI_ONLY_TGA
#define STBI_ONLY_PSD
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
    if (ext == "webp" || (data_size >= 12 && std::memcmp(data, "RIFF", 4) == 0 && std::memcmp(data + 8, "WEBP", 4) == 0)) {
        return decode_webp(data, data_size, target_width, target_height, out_result);
    }
    if (ext == "svg") {
        return decode_svg(data, data_size, target_width, target_height, out_result);
    }
    // Everything else (png/jpg/bmp/gif/tga/psd, and an empty/unknown extension
    // for raw in-memory bytes) goes through stb_image, which sniffs the format
    // from the data itself.
    return decode_stb(data, data_size, target_width, target_height, out_result);
}

extern "C" bool guava_image_dimensions_memory(const uint8_t* data, size_t data_size,
                                                const char* extension, int32_t* width, int32_t* height) {
    if (!data || !data_size || !width || !height || data_size > INT_MAX) return false;
    const std::string ext = lower_extension(extension);
    int w = 0, h = 0, channels = 0;
    if (ext == "svg") {
        auto document = lunasvg::Document::loadFromData(std::string(reinterpret_cast<const char*>(data), data_size));
        if (!document) return false;
        if (!std::isfinite(document->width()) || !std::isfinite(document->height()) ||
            document->width() > INT_MAX || document->height() > INT_MAX) return false;
        w = static_cast<int>(std::ceil(document->width()));
        h = static_cast<int>(std::ceil(document->height()));
    } else if (ext == "webp" || (data_size >= 12 && std::memcmp(data, "RIFF", 4) == 0 && std::memcmp(data + 8, "WEBP", 4) == 0)) {
        if (!WebPGetInfo(data, data_size, &w, &h)) return false;
    } else {
        if (!stbi_info_from_memory(data, static_cast<int>(data_size), &w, &h, &channels)) return false;
    }
    if (w <= 0 || h <= 0) return false;
    *width = w; *height = h;
    return true;
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

// MARK: - Animation

namespace {

struct AnimationFrames {
    std::vector<uint8_t> pixels;
    std::vector<int32_t> durations;
    int width = 0;
    int height = 0;
    int loop_count = 0;
};

bool fail_animation(GuavaImageAnimationResult* result, const char* message) {
    if (result) {
        result->pixels = nullptr;
        result->durations_ms = nullptr;
        result->width = result->height = result->frame_count = result->loop_count = 0;
        result->error_message = copy_message(message);
    }
    return false;
}

void append_frame(AnimationFrames& frames, const uint8_t* canvas, int canvas_width, int canvas_height,
                  int duration, int target_width, int target_height) {
    const int out_width = target_width > 0 ? target_width : canvas_width;
    const int out_height = target_height > 0 ? target_height : canvas_height;
    std::vector<uint8_t> frame = resize_rgba(canvas, canvas_width, canvas_height, out_width, out_height);
    frames.pixels.insert(frames.pixels.end(), frame.begin(), frame.end());
    frames.durations.push_back(duration);
    frames.width = out_width;
    frames.height = out_height;
}

bool decode_gif_frames(const uint8_t* data, size_t data_size, int target_width, int target_height,
                       int max_frames, AnimationFrames& frames, const char** error) {
    int* delays = nullptr;
    int width = 0, height = 0, count = 0, channels = 0;
    stbi_uc* decoded = stbi_load_gif_from_memory(data, static_cast<int>(data_size), &delays,
                                                 &width, &height, &count, &channels, 4);
    if (decoded == nullptr) { *error = stbi_failure_reason(); return false; }
    const size_t frame_bytes = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
    const int kept = std::min(count, max_frames);
    for (int index = 0; index < kept; ++index) {
        append_frame(frames, decoded + frame_bytes * index, width, height,
                     delays ? delays[index] : 100, target_width, target_height);
    }
    stbi_image_free(decoded);
    std::free(delays);
    return kept > 0;
}

uint32_t read_le24(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16); }
uint32_t read_le32(const uint8_t* p) { return read_le24(p) | (static_cast<uint32_t>(p[3]) << 24); }

/// Animated WebP without libwebpdemux: walk the RIFF chunks, decode each
/// ANMF payload (ALPH + VP8/VP8L, which libwebp accepts without a RIFF
/// header) and composite with the frame's blend and dispose flags.
bool decode_webp_frames(const uint8_t* data, size_t data_size, int target_width, int target_height,
                        int max_frames, AnimationFrames& frames, const char** error) {
    if (data_size < 12 || std::memcmp(data, "RIFF", 4) != 0 || std::memcmp(data + 8, "WEBP", 4) != 0) {
        *error = "not a WebP container"; return false;
    }
    const size_t riff_end = std::min(data_size, static_cast<size_t>(read_le32(data + 4)) + 8);
    int canvas_width = 0, canvas_height = 0;
    std::vector<uint8_t> canvas;
    struct Previous { int x, y, w, h; bool dispose; } previous{0, 0, 0, 0, false};
    size_t offset = 12;
    while (offset + 8 <= riff_end && static_cast<int>(frames.durations.size()) < max_frames) {
        const uint8_t* chunk = data + offset;
        const size_t size = read_le32(chunk + 4);
        const uint8_t* payload = chunk + 8;
        if (offset + 8 + size > riff_end) break;
        if (std::memcmp(chunk, "VP8X", 4) == 0 && size >= 10) {
            canvas_width = static_cast<int>(read_le24(payload + 4)) + 1;
            canvas_height = static_cast<int>(read_le24(payload + 7)) + 1;
            if (static_cast<int64_t>(canvas_width) * canvas_height > 64LL * 1024 * 1024) {
                *error = "animated WebP canvas is too large"; return false;
            }
            canvas.assign(static_cast<size_t>(canvas_width) * canvas_height * 4, 0);
        } else if (std::memcmp(chunk, "ANIM", 4) == 0 && size >= 6) {
            frames.loop_count = payload[4] | (payload[5] << 8);
        } else if (std::memcmp(chunk, "ANMF", 4) == 0 && size >= 16 && !canvas.empty()) {
            const int x = static_cast<int>(read_le24(payload)) * 2;
            const int y = static_cast<int>(read_le24(payload + 3)) * 2;
            const int duration = static_cast<int>(read_le24(payload + 12));
            const uint8_t flags = payload[15];
            const bool blend = (flags & 0x02) == 0;
            const bool dispose = (flags & 0x01) != 0;
            if (previous.dispose) {
                for (int row = previous.y; row < std::min(canvas_height, previous.y + previous.h); ++row) {
                    const int left = std::max(0, previous.x), right = std::min(canvas_width, previous.x + previous.w);
                    if (right > left) {
                        std::memset(canvas.data() + (static_cast<size_t>(row) * canvas_width + left) * 4, 0,
                                    static_cast<size_t>(right - left) * 4);
                    }
                }
            }
            int frame_width = 0, frame_height = 0;
            uint8_t* rgba = WebPDecodeRGBA(payload + 16, size - 16, &frame_width, &frame_height);
            if (rgba == nullptr) { *error = "libwebp failed to decode an animation frame"; return false; }
            for (int row = 0; row < frame_height; ++row) {
                const int cy = y + row;
                if (cy < 0 || cy >= canvas_height) continue;
                for (int column = 0; column < frame_width; ++column) {
                    const int cx = x + column;
                    if (cx < 0 || cx >= canvas_width) continue;
                    const uint8_t* src = rgba + (static_cast<size_t>(row) * frame_width + column) * 4;
                    uint8_t* dst = canvas.data() + (static_cast<size_t>(cy) * canvas_width + cx) * 4;
                    if (!blend || src[3] == 255) { std::memcpy(dst, src, 4); continue; }
                    if (src[3] == 0) continue;
                    const double sa = src[3] / 255.0, da = dst[3] / 255.0;
                    const double oa = sa + da * (1 - sa);
                    for (int c = 0; c < 3; ++c) {
                        dst[c] = static_cast<uint8_t>(std::clamp(std::round((src[c] * sa + dst[c] * da * (1 - sa)) / oa), 0.0, 255.0));
                    }
                    dst[3] = static_cast<uint8_t>(std::round(oa * 255));
                }
            }
            WebPFree(rgba);
            previous = Previous{x, y, frame_width, frame_height, dispose};
            append_frame(frames, canvas.data(), canvas_width, canvas_height, duration, target_width, target_height);
        }
        offset += 8 + size + (size & 1);
    }
    if (frames.durations.empty()) {
        // A still WebP: one frame through the regular decoder.
        int width = 0, height = 0;
        uint8_t* rgba = WebPDecodeRGBA(data, data_size, &width, &height);
        if (rgba == nullptr) { *error = "libwebp failed to decode image"; return false; }
        append_frame(frames, rgba, width, height, 0, target_width, target_height);
        WebPFree(rgba);
    }
    return true;
}

} // namespace

extern "C" bool guava_image_decode_animation_memory(const uint8_t* data,
                                                     size_t data_size,
                                                     const char* extension,
                                                     int32_t target_width,
                                                     int32_t target_height,
                                                     int32_t max_frames,
                                                     GuavaImageAnimationResult* out_result) {
    if (out_result == nullptr) return false;
    *out_result = GuavaImageAnimationResult{};
    if (data == nullptr || data_size == 0 || data_size > INT_MAX) return fail_animation(out_result, "empty image data");
    const int limit = std::max(1, static_cast<int>(max_frames));
    const std::string ext = lower_extension(extension);
    AnimationFrames frames;
    const char* error = "unsupported animation format";
    bool ok = false;
    if (ext == "webp" || (data_size >= 12 && std::memcmp(data, "RIFF", 4) == 0 && std::memcmp(data + 8, "WEBP", 4) == 0)) {
        ok = decode_webp_frames(data, data_size, target_width, target_height, limit, frames, &error);
    } else if (ext == "gif" || (data_size >= 6 && std::memcmp(data, "GIF8", 4) == 0)) {
        ok = decode_gif_frames(data, data_size, target_width, target_height, limit, frames, &error);
    }
    if (!ok || frames.durations.empty()) return fail_animation(out_result, error);
    out_result->pixels = static_cast<uint8_t*>(std::malloc(frames.pixels.size()));
    out_result->durations_ms = static_cast<int32_t*>(std::malloc(frames.durations.size() * sizeof(int32_t)));
    if (out_result->pixels == nullptr || out_result->durations_ms == nullptr) {
        guava_image_animation_free(out_result);
        return fail_animation(out_result, "out of memory while copying animation frames");
    }
    std::memcpy(out_result->pixels, frames.pixels.data(), frames.pixels.size());
    std::memcpy(out_result->durations_ms, frames.durations.data(), frames.durations.size() * sizeof(int32_t));
    out_result->width = frames.width;
    out_result->height = frames.height;
    out_result->frame_count = static_cast<int32_t>(frames.durations.size());
    out_result->loop_count = frames.loop_count;
    return true;
}

extern "C" void guava_image_animation_free(GuavaImageAnimationResult* result) {
    if (result == nullptr) return;
    std::free(result->pixels);
    std::free(result->durations_ms);
    std::free(result->error_message);
    *result = GuavaImageAnimationResult{};
}
