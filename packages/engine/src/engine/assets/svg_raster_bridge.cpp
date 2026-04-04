#include "svg_raster_bridge.h"

#include <lunasvg.h>

#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <string>

namespace {

constexpr int kFallbackIconSize = 24;

int resolveSizeAxis(uint32_t requested) {
    return requested > 0 ? static_cast<int>(requested) : 0;
}

void resolveRasterSize(const lunasvg::Document& document, uint32_t requested_width, uint32_t requested_height, int* out_width, int* out_height) {
    const float intrinsic_width = document.width();
    const float intrinsic_height = document.height();
    const bool has_intrinsic_size = intrinsic_width > 0.0f && intrinsic_height > 0.0f;

    int width = resolveSizeAxis(requested_width);
    int height = resolveSizeAxis(requested_height);

    if (width > 0 && height > 0) {
        *out_width = width;
        *out_height = height;
        return;
    }

    if (has_intrinsic_size) {
        if (width <= 0 && height <= 0) {
            width = static_cast<int>(std::ceil(intrinsic_width));
            height = static_cast<int>(std::ceil(intrinsic_height));
        } else if (width > 0) {
            height = static_cast<int>(std::ceil((static_cast<float>(width) * intrinsic_height) / intrinsic_width));
        } else {
            width = static_cast<int>(std::ceil((static_cast<float>(height) * intrinsic_width) / intrinsic_height));
        }
    } else {
        const int fallback = width > 0 ? width : (height > 0 ? height : kFallbackIconSize);
        if (width <= 0) {
            width = fallback;
        }
        if (height <= 0) {
            height = fallback;
        }
    }

    if (width <= 0) {
        width = kFallbackIconSize;
    }
    if (height <= 0) {
        height = kFallbackIconSize;
    }

    *out_width = width;
    *out_height = height;
}

void applyTintIfRequested(lunasvg::Document* document, GuavaSvgRasterOptions options) {
    if (document == nullptr || !options.apply_tint) {
        return;
    }

    char stylesheet[192];
    const double alpha = static_cast<double>(options.tint_rgba[3]) / 255.0;
    std::snprintf(
        stylesheet,
        sizeof(stylesheet),
        "svg, path, circle, rect, polygon, polyline, line { color: rgba(%u, %u, %u, %.6f); fill: currentColor !important; stroke: currentColor !important; }",
        static_cast<unsigned>(options.tint_rgba[0]),
        static_cast<unsigned>(options.tint_rgba[1]),
        static_cast<unsigned>(options.tint_rgba[2]),
        alpha
    );
    document->applyStyleSheet(stylesheet);
}

} // namespace

extern "C" bool guava_svg_rasterize_file(
    const char* path,
    size_t path_len,
    GuavaSvgRasterOptions options,
    GuavaSvgRasterImage* out_image
) {
    if (path == nullptr || path_len == 0 || out_image == nullptr) {
        return false;
    }

    *out_image = GuavaSvgRasterImage{0, 0, nullptr, 0};

    const std::string filename(path, path_len);
    auto document = lunasvg::Document::loadFromFile(filename);
    if (!document) {
        return false;
    }

    applyTintIfRequested(document.get(), options);

    int raster_width = 0;
    int raster_height = 0;
    resolveRasterSize(*document, options.width, options.height, &raster_width, &raster_height);

    auto bitmap = document->renderToBitmap(raster_width, raster_height, 0x00000000u);
    if (bitmap.isNull() || bitmap.width() <= 0 || bitmap.height() <= 0) {
        return false;
    }

    bitmap.convertToRGBA();

    const auto width = bitmap.width();
    const auto height = bitmap.height();
    const size_t row_bytes = static_cast<size_t>(width) * 4u;
    const size_t total_bytes = row_bytes * static_cast<size_t>(height);

    auto* pixels = static_cast<uint8_t*>(std::malloc(total_bytes));
    if (pixels == nullptr) {
        return false;
    }

    const auto* source = bitmap.data();
    const size_t source_stride = static_cast<size_t>(bitmap.stride());
    for (int y = 0; y < height; ++y) {
        const auto* source_row = source + (static_cast<size_t>(y) * source_stride);
        auto* destination_row = pixels + (static_cast<size_t>(y) * row_bytes);
        for (int x = 0; x < width; ++x) {
            const auto source_offset = static_cast<size_t>(x) * 4u;
            destination_row[source_offset + 0] = source_row[source_offset + 2];
            destination_row[source_offset + 1] = source_row[source_offset + 1];
            destination_row[source_offset + 2] = source_row[source_offset + 0];
            destination_row[source_offset + 3] = source_row[source_offset + 3];
        }
    }

    out_image->width = static_cast<uint32_t>(width);
    out_image->height = static_cast<uint32_t>(height);
    out_image->pixels = pixels;
    out_image->length = total_bytes;
    return true;
}

extern "C" void guava_svg_free_image(GuavaSvgRasterImage* image) {
    if (image == nullptr) {
        return;
    }

    std::free(image->pixels);
    image->width = 0;
    image->height = 0;
    image->pixels = nullptr;
    image->length = 0;
}
