#include "include/ocio_bridge.h"
#include <OpenColorIO/OpenColorIO.h>
#include <cstring>
#include <string>
#include <vector>

namespace OCIO = OCIO_NAMESPACE;

struct GuavaOCIOContextImpl {
    OCIO::ConstConfigRcPtr config;
    std::vector<std::string> colorSpaceNames;
};

GuavaOCIOContext guava_ocio_context_create(const char* config_path) {
    if (!config_path) return nullptr;
    try {
        auto config = OCIO::Config::CreateFromFile(config_path);
        if (!config) return nullptr;

        auto* ctx = new GuavaOCIOContextImpl();
        ctx->config = config;

        int count = config->getNumColorSpaces();
        ctx->colorSpaceNames.reserve(count);
        for (int i = 0; i < count; ++i) {
            ctx->colorSpaceNames.push_back(config->getColorSpaceNameByIndex(i));
        }
        return ctx;
    } catch (const OCIO::Exception&) {
        return nullptr;
    }
}

void guava_ocio_context_destroy(GuavaOCIOContext ctx) {
    delete ctx;
}

bool guava_ocio_context_is_valid(GuavaOCIOContext ctx) {
    return ctx != nullptr && ctx->config != nullptr;
}

int32_t guava_ocio_get_color_space_count(GuavaOCIOContext ctx) {
    if (!ctx) return 0;
    return static_cast<int32_t>(ctx->colorSpaceNames.size());
}

const char* guava_ocio_get_color_space_name(GuavaOCIOContext ctx, int32_t index) {
    if (!ctx || index < 0 || static_cast<size_t>(index) >= ctx->colorSpaceNames.size()) {
        return nullptr;
    }
    return ctx->colorSpaceNames[index].c_str();
}

bool guava_ocio_apply_transform_rgba(GuavaOCIOContext ctx,
                                     const GuavaOCIOTransformDesc* desc,
                                     float* pixels,
                                     int32_t width,
                                     int32_t height) {
    if (!ctx || !desc || !pixels || width <= 0 || height <= 0) return false;
    if (!desc->input_color_space || !desc->output_color_space) return false;

    try {
        OCIO::ConstProcessorRcPtr processor;
        std::string srcName(desc->input_color_space);
        std::string dstName(desc->output_color_space);

        // Build the transform from src to dst color space.
        // If view_transform and display are provided, they are used;
        // otherwise a direct src→dst conversion is performed.
        if (desc->view_transform && desc->view_transform[0] != '\0'
            && desc->display && desc->display[0] != '\0') {
            processor = ctx->config->getProcessor(
                srcName.c_str(),
                desc->display,
                desc->view_transform,
                OCIO::TRANSFORM_DIR_FORWARD
            );
        } else {
            processor = ctx->config->getProcessor(srcName.c_str(), dstName.c_str());
        }

        if (!processor) return false;

        auto cpuProcessor = processor->getOptimizedCPUProcessor(
            OCIO::BIT_DEPTH_F32,
            OCIO::BIT_DEPTH_F32,
            OCIO::OPTIMIZATION_DEFAULT
        );

        OCIO::PackedImageDesc img(pixels, width, height, 4);
        cpuProcessor->apply(img);
        return true;
    } catch (const OCIO::Exception&) {
        return false;
    }
}
