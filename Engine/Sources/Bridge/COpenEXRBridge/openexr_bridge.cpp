#include "include/openexr_bridge.h"
#include <OpenEXR/ImfMultiPartOutputFile.h>
#include <OpenEXR/ImfMultiPartInputFile.h>
#include <OpenEXR/ImfOutputPart.h>
#include <OpenEXR/ImfInputPart.h>
#include <OpenEXR/ImfHeader.h>
#include <OpenEXR/ImfChannelList.h>
#include <OpenEXR/ImfFrameBuffer.h>
#include <OpenEXR/ImfPixelType.h>
#include <OpenEXR/ImfStringAttribute.h>
#include <Imath/half.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <sstream>

static int channelCount(const Imf::ChannelList& channels) {
    int n = 0;
    for (auto it = channels.begin(); it != channels.end(); ++it) { ++n; }
    return n;
}

// ── Writer context ──────────────────────────────────────────────────────────

struct GuavaEXRWriterLayer {
    std::string name;
    Imf::Header header;
    Imf::PixelType pixelType;
    std::vector<std::string> channelOrder;  // original insertion order
    std::vector<float> pixels;  // interleaved, always float, in channelOrder sequence
};

struct GuavaEXRWriterContext {
    std::string path;
    int width;
    int height;
    std::vector<GuavaEXRWriterLayer> layers;
};

GuavaEXRContext guava_exr_writer_create(const char* path,
                                        int32_t width,
                                        int32_t height) {
    if (!path || width <= 0 || height <= 0) return nullptr;
    auto* ctx = new GuavaEXRWriterContext();
    ctx->path = path;
    ctx->width = width;
    ctx->height = height;
    return reinterpret_cast<GuavaEXRContext>(ctx);
}

void guava_exr_writer_destroy(GuavaEXRContext ctx) {
    delete reinterpret_cast<GuavaEXRWriterContext*>(ctx);
}

bool guava_exr_writer_add_layer(GuavaEXRContext ctx,
                                const GuavaEXRLayerDesc* layer,
                                GuavaEXRPixelType pixel_type) {
    if (!ctx || !layer || !layer->name || !layer->channels) return false;
    auto* w = reinterpret_cast<GuavaEXRWriterContext*>(ctx);

    Imf::PixelType pt = Imf::FLOAT; // Always use float for simplicity

    Imath::Box2i displayWin(Imath::V2i(0, 0), Imath::V2i(w->width - 1, w->height - 1));
    Imath::Box2i dataWin(Imath::V2i(0, 0), Imath::V2i(w->width - 1, w->height - 1));
    Imf::Header header(displayWin, dataWin);
    header.setType("scanlineimage");
    header.setName(layer->name);

    // Parse channels "R,G,B" → add each; also store original order
    std::string chStr(layer->channels);
    header.insert("guavaChannelOrder", Imf::StringAttribute(chStr));
    std::istringstream ss(chStr);
    std::string ch;
    std::vector<std::string> order;
    while (std::getline(ss, ch, ',')) {
        if (!ch.empty()) {
            header.channels().insert(ch.c_str(), Imf::Channel(pt));
            order.push_back(ch);
        }
    }

    GuavaEXRWriterLayer l;
    l.name = layer->name;
    l.header = header;
    l.pixelType = pt;
    l.channelOrder = order;
    int chCount = static_cast<int>(order.size());
    l.pixels.resize(w->width * w->height * chCount, 0.0f);

    w->layers.push_back(std::move(l));
    return true;
}

bool guava_exr_writer_set_layer_pixels(GuavaEXRContext ctx,
                                       const char* layer_name,
                                       const float* pixels,
                                       int32_t pixel_count) {
    if (!ctx || !layer_name || !pixels) return false;
    auto* w = reinterpret_cast<GuavaEXRWriterContext*>(ctx);

    for (auto& layer : w->layers) {
        if (layer.name == layer_name) {
            size_t n = static_cast<size_t>(pixel_count);
            if (n > layer.pixels.size()) n = layer.pixels.size();
            std::memcpy(layer.pixels.data(), pixels, n * sizeof(float));
            return true;
        }
    }
    return false;
}

bool guava_exr_writer_write(GuavaEXRContext ctx) {
    if (!ctx) return false;
    auto* w = reinterpret_cast<GuavaEXRWriterContext*>(ctx);
    if (w->layers.empty()) return false;

    try {
        std::vector<Imf::Header> headers;
        headers.reserve(w->layers.size());
        for (auto& layer : w->layers) {
            headers.push_back(layer.header);
        }

        Imf::MultiPartOutputFile file(w->path.c_str(), headers.data(),
                                      static_cast<int>(headers.size()));

        for (int part = 0; part < static_cast<int>(w->layers.size()); ++part) {
            auto& layer = w->layers[part];
            int chCount = static_cast<int>(layer.channelOrder.size());
            Imf::OutputPart out(file, part);

            // Build mapping: alphabetical ChannelList position → declaration offset
            std::vector<int> alphaToDecl(chCount);
            int alphaIdx = 0;
            for (auto it = layer.header.channels().begin();
                 it != layer.header.channels().end(); ++it, ++alphaIdx) {
                std::string chName(it.name());
                auto pos = std::find(layer.channelOrder.begin(),
                                     layer.channelOrder.end(), chName);
                alphaToDecl[alphaIdx] = (pos != layer.channelOrder.end())
                    ? static_cast<int>(pos - layer.channelOrder.begin()) : alphaIdx;
            }

            // Reorder pixel data from declaration order to alphabetical order
            size_t pixelCount = static_cast<size_t>(w->width) * w->height;
            std::vector<float> alphaBuf = layer.pixels;
            for (size_t px = 0; px < pixelCount; ++px) {
                for (int c = 0; c < chCount; ++c) {
                    alphaBuf[px * chCount + c] = layer.pixels[px * chCount + alphaToDecl[c]];
                }
            }

            Imf::FrameBuffer fb;
            size_t rowBytes = w->width * chCount * sizeof(float);
            char* base = reinterpret_cast<char*>(alphaBuf.data());

            alphaIdx = 0;
            for (auto it = layer.header.channels().begin();
                 it != layer.header.channels().end(); ++it, ++alphaIdx) {
                fb.insert(it.name(),
                          Imf::Slice(Imf::FLOAT,
                                     base + alphaIdx * sizeof(float),
                                     sizeof(float) * chCount,
                                     rowBytes));
            }

            out.setFrameBuffer(fb);
            out.writePixels(w->height);
        }
        return true;
    } catch (const std::exception&) {
        return false;
    }
}

// ── Reader context ──────────────────────────────────────────────────────────

struct GuavaEXRReaderLayer {
    std::string name;
    std::string channels;
    int channelCount;
};

struct GuavaEXRReaderContext {
    Imf::MultiPartInputFile* file;
    int partCount;
    std::vector<GuavaEXRReaderLayer> layers;
    int width;
    int height;
};

GuavaEXRContext guava_exr_reader_open(const char* path) {
    if (!path) return nullptr;
    try {
        auto* ctx = new GuavaEXRReaderContext();
        ctx->file = new Imf::MultiPartInputFile(path);
        ctx->partCount = ctx->file->parts();

        for (int i = 0; i < ctx->partCount; ++i) {
            Imf::InputPart part(*ctx->file, i);
            const Imf::Header& h = part.header();
            const Imath::Box2i& dw = h.dataWindow();

            if (i == 0) {
                ctx->width = dw.max.x - dw.min.x + 1;
                ctx->height = dw.max.y - dw.min.y + 1;
            }

            GuavaEXRReaderLayer layer;
            layer.name = h.hasName() ? h.name() : ("layer_" + std::to_string(i));
            std::string chStr;
            for (auto it = h.channels().begin(); it != h.channels().end(); ++it) {
                if (!chStr.empty()) chStr += ",";
                chStr += it.name();
            }
            layer.channels = chStr;
            layer.channelCount = channelCount(h.channels());
            ctx->layers.push_back(layer);
        }
        return reinterpret_cast<GuavaEXRContext>(ctx);
    } catch (const std::exception&) {
        return nullptr;
    }
}

void guava_exr_reader_close(GuavaEXRContext ctx) {
    if (!ctx) return;
    auto* r = reinterpret_cast<GuavaEXRReaderContext*>(ctx);
    delete r->file;
    delete r;
}

int32_t guava_exr_reader_get_width(GuavaEXRContext ctx) {
    if (!ctx) return 0;
    return reinterpret_cast<GuavaEXRReaderContext*>(ctx)->width;
}

int32_t guava_exr_reader_get_height(GuavaEXRContext ctx) {
    if (!ctx) return 0;
    return reinterpret_cast<GuavaEXRReaderContext*>(ctx)->height;
}

int32_t guava_exr_reader_get_layer_count(GuavaEXRContext ctx) {
    if (!ctx) return 0;
    return static_cast<int32_t>(reinterpret_cast<GuavaEXRReaderContext*>(ctx)->layers.size());
}

bool guava_exr_reader_get_layer_desc(GuavaEXRContext ctx,
                                     int32_t index,
                                     GuavaEXRLayerDesc* out_desc) {
    if (!ctx || !out_desc || index < 0) return false;
    auto* r = reinterpret_cast<GuavaEXRReaderContext*>(ctx);
    if (static_cast<size_t>(index) >= r->layers.size()) return false;

    auto& layer = r->layers[index];
    // WARNING: pointers dangle after the context is destroyed or this function
    // is called again. Callers must copy the strings immediately.
    out_desc->name = layer.name.c_str();
    out_desc->channels = layer.channels.c_str();
    out_desc->channel_count = layer.channelCount;
    return true;
}

bool guava_exr_reader_read_layer_pixels(GuavaEXRContext ctx,
                                        const char* layer_name,
                                        float* out_pixels,
                                        int32_t pixel_count) {
    if (!ctx || !layer_name || !out_pixels || pixel_count <= 0) return false;
    auto* r = reinterpret_cast<GuavaEXRReaderContext*>(ctx);

    int partIdx = -1;
    for (int i = 0; i < r->partCount; ++i) {
        const Imf::Header& h = r->file->header(i);
        std::string name = h.hasName() ? h.name() : ("layer_" + std::to_string(i));
        if (name == layer_name) {
            partIdx = i;
            break;
        }
    }
    if (partIdx < 0) return false;

    try {
        Imf::InputPart part(*r->file, partIdx);
        const Imath::Box2i& dw = part.header().dataWindow();
        int dwWidth = dw.max.x - dw.min.x + 1;
        int dwHeight = dw.max.y - dw.min.y + 1;
        int chCount = channelCount(part.header().channels());

        // Allocate temp buffer for native pixel types
        int totalPixels = dwWidth * dwHeight * chCount;
        std::vector<float> tempBuf(totalPixels, 0.0f);

        // Set up framebuffer with float pointers (OpenEXR will convert from
        // half/uint to float as needed)
        Imf::FrameBuffer fb;
        size_t rowBytes = dwWidth * chCount * sizeof(float);
        char* base = reinterpret_cast<char*>(tempBuf.data());

        int chIdx = 0;
        for (auto it = part.header().channels().begin();
             it != part.header().channels().end(); ++it, ++chIdx) {
            fb.insert(it.name(),
                      Imf::Slice(Imf::FLOAT,
                                 base + chIdx * sizeof(float),
                                 sizeof(float) * chCount,
                                 rowBytes));
        }

        part.setFrameBuffer(fb);
        part.readPixels(dw.min.y, dw.max.y);

        // Reorder from alphabetical back to original declaration order if available
        const auto* orderAttr = part.header().findTypedAttribute<Imf::StringAttribute>("guavaChannelOrder");
        if (orderAttr) {
            std::string orderStr = orderAttr->value();
            std::vector<std::string> declOrder;
            std::istringstream ss(orderStr);
            std::string ch;
            while (std::getline(ss, ch, ',')) {
                if (!ch.empty()) declOrder.push_back(ch);
            }

            // Build alphabetical → declaration index mapping
            std::vector<std::string> alphaOrder;
            for (auto it = part.header().channels().begin();
                 it != part.header().channels().end(); ++it) {
                alphaOrder.push_back(it.name());
            }

            std::vector<int> alphaToDecl(alphaOrder.size());
            for (size_t ai = 0; ai < alphaOrder.size(); ++ai) {
                auto it = std::find(declOrder.begin(), declOrder.end(), alphaOrder[ai]);
                alphaToDecl[ai] = (it != declOrder.end())
                    ? static_cast<int>(it - declOrder.begin()) : static_cast<int>(ai);
            }

            // Reorder: tempBuf (alphabetical) → out_pixels (declaration)
            size_t pxCount = static_cast<size_t>(dwWidth) * dwHeight;
            int chCount = static_cast<int>(alphaOrder.size());
            std::vector<float> reordered = tempBuf;
            for (size_t px = 0; px < pxCount; ++px) {
                for (int c = 0; c < chCount; ++c) {
                    reordered[px * chCount + c] = tempBuf[px * chCount + alphaToDecl[c]];
                }
            }
            size_t n = static_cast<size_t>(pixel_count);
            if (n > reordered.size()) n = reordered.size();
            std::memcpy(out_pixels, reordered.data(), n * sizeof(float));
        } else {
            // No channel order attribute — return in alphabetical order as-is
            size_t n = static_cast<size_t>(pixel_count);
            if (n > tempBuf.size()) n = tempBuf.size();
            std::memcpy(out_pixels, tempBuf.data(), n * sizeof(float));
        }
        return true;
    } catch (const std::exception&) {
        return false;
    }
}
