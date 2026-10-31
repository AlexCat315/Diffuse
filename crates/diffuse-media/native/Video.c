#include "Decoder.h"

int gm_read_video(GMDecoder *d, const uint8_t **rgba, int *stride, double *seconds, char *error, size_t capacity) {
    if (!d || d->resampler) return gm_error(AVERROR(EINVAL), error, capacity);
    for (;;) {
        int status = gm_next_frame(d, error, capacity);
        if (status <= 0) return status;
        *seconds = gm_frame_time(d);
        if (d->seek_time >= 0 && *seconds + 0.000001 < d->seek_time) continue;
        d->seek_time = -1;
        int width = d->frame->width, height = d->frame->height;
        if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return gm_error(AVERROR_INVALIDDATA, error, capacity);
        size_t bytes = (size_t)width * height * 4;
        av_fast_malloc(&d->output, &d->output_size, bytes);
        if (!d->output) return gm_error(AVERROR(ENOMEM), error, capacity);
        d->scaler = sws_getCachedContext(d->scaler, width, height, d->frame->format,
            width, height, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
        if (!d->scaler) return gm_error(AVERROR(ENOMEM), error, capacity);
        uint8_t *output[] = {d->output};
        int strides[] = {width * 4};
        status = sws_scale(d->scaler, (const uint8_t *const *)d->frame->data, d->frame->linesize, 0, height, output, strides);
        if (status < 0) return gm_error(status, error, capacity);
        *rgba = d->output;
        *stride = strides[0];
        return 1;
    }
}
