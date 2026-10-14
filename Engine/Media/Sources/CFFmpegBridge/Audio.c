#include "Decoder.h"
#include <math.h>

int gm_read_audio(GMDecoder *d, const float **samples, int *frames, char *error, size_t capacity) {
    if (!d || !d->resampler) return gm_error(AVERROR(EINVAL), error, capacity);
    for (;;) {
        int status = gm_next_frame(d, error, capacity);
        if (status < 0) return status;
        int input_frames = status ? d->frame->nb_samples : 0;
        int count = swr_get_out_samples(d->resampler, input_frames);
        if (count < 0 || count > INT_MAX / (2 * (int)sizeof(float))) return gm_error(AVERROR(ENOMEM), error, capacity);
        av_fast_malloc(&d->output, &d->output_size, (size_t)count * 2 * sizeof(float));
        if (!d->output && count) return gm_error(AVERROR(ENOMEM), error, capacity);
        uint8_t *output[] = { d->output };
        int converted = swr_convert(d->resampler, output, count,
            status ? (const uint8_t **)d->frame->extended_data : NULL, input_frames);
        if (converted < 0) return gm_error(converted, error, capacity);
        if (!converted) { if (!status) return 0; continue; }
        int skip = 0;
        if (d->seek_time >= 0 && status) {
            double delta = d->seek_time - gm_frame_time(d);
            if (delta > 0) skip = (int)fmin(converted, ceil(delta * 48000));
            if (skip == converted) continue;
            d->seek_time = -1;
        }
        *samples = ((float *)d->output) + skip * 2;
        *frames = converted - skip;
        return 1;
    }
}
