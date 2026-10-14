#include "Decoder.h"
#include <math.h>
#include <stdio.h>

int gm_error(int code, char *error, size_t capacity) {
    if (error && capacity) av_strerror(code, error, capacity);
    return -1;
}

GMDecoder *gm_open(const char *path, int video, char *error, size_t capacity) {
    GMDecoder *d = av_mallocz(sizeof(*d));
    if (!d) { gm_error(AVERROR(ENOMEM), error, capacity); return NULL; }
    d->seek_time = -1;
    d->format = avformat_alloc_context();
    if (!d->format) { gm_error(AVERROR(ENOMEM), error, capacity); gm_close(d); return NULL; }
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    int status = avformat_open_input(&d->format, path, NULL, &options);
    av_dict_free(&options);
    if (status < 0) goto failed;
    status = avformat_find_stream_info(d->format, NULL);
    if (status < 0) goto failed;
    const AVCodec *codec = NULL;
    status = av_find_best_stream(d->format, video ? AVMEDIA_TYPE_VIDEO : AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (status < 0) goto failed;
    d->stream = status;
    d->codec = avcodec_alloc_context3(codec);
    if (!d->codec) { status = AVERROR(ENOMEM); goto failed; }
    status = avcodec_parameters_to_context(d->codec, d->format->streams[d->stream]->codecpar);
    if (status < 0) goto failed;
    d->codec->thread_count = 2;
    d->codec->max_pixels = 64LL * 1024 * 1024;
    status = avcodec_open2(d->codec, codec, NULL);
    if (status < 0) goto failed;
    d->packet = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->packet || !d->frame) { status = AVERROR(ENOMEM); goto failed; }
    if (!video) {
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        status = swr_alloc_set_opts2(&d->resampler, &stereo, AV_SAMPLE_FMT_FLT, 48000,
                                    &d->codec->ch_layout, d->codec->sample_fmt, d->codec->sample_rate, 0, NULL);
        if (status < 0) goto failed;
        status = swr_init(d->resampler);
        if (status < 0) goto failed;
    }
    return d;
failed:
    gm_error(status, error, capacity);
    gm_close(d);
    return NULL;
}

void gm_close(GMDecoder *d) {
    if (!d) return;
    swr_free(&d->resampler);
    sws_freeContext(d->scaler);
    av_free(d->output);
    av_frame_free(&d->frame);
    av_packet_free(&d->packet);
    avcodec_free_context(&d->codec);
    avformat_close_input(&d->format);
    av_free(d);
}

GMStreamInfo gm_info(const GMDecoder *d) {
    GMStreamInfo info = {0};
    if (!d) return info;
    AVStream *stream = d->format->streams[d->stream];
    info.duration = stream->duration != AV_NOPTS_VALUE ? stream->duration * av_q2d(stream->time_base) :
        d->format->duration != AV_NOPTS_VALUE ? (double)d->format->duration / AV_TIME_BASE : 0;
    info.width = d->codec->width;
    info.height = d->codec->height;
    if (d->resampler) { info.sample_rate = 48000; info.channels = 2; }
    return info;
}

double gm_frame_time(GMDecoder *d) {
    AVStream *stream = d->format->streams[d->stream];
    int64_t time = d->frame->best_effort_timestamp;
    int64_t start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
    return time == AV_NOPTS_VALUE ? 0 : (time - start) * av_q2d(stream->time_base);
}

int gm_seek(GMDecoder *d, double seconds, char *error, size_t capacity) {
    if (!d || !isfinite(seconds) || seconds < 0) return gm_error(AVERROR(EINVAL), error, capacity);
    AVStream *stream = d->format->streams[d->stream];
    double ticks = seconds / av_q2d(stream->time_base);
    if (ticks > (double)(INT64_MAX / 2)) return gm_error(AVERROR(EINVAL), error, capacity);
    int64_t start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
    int status = av_seek_frame(d->format, d->stream, (int64_t)ticks + start, AVSEEK_FLAG_BACKWARD);
    if (status < 0) return gm_error(status, error, capacity);
    avcodec_flush_buffers(d->codec);
    av_packet_unref(d->packet);
    av_frame_unref(d->frame);
    if (d->resampler) { swr_close(d->resampler); status = swr_init(d->resampler); }
    if (status < 0) return gm_error(status, error, capacity);
    d->draining = 0;
    d->seek_time = seconds;
    return 0;
}

int gm_next_frame(GMDecoder *d, char *error, size_t capacity) {
    for (;;) {
        int status = avcodec_receive_frame(d->codec, d->frame);
        if (status == 0) return 1;
        if (status == AVERROR_EOF) return 0;
        if (status != AVERROR(EAGAIN)) return gm_error(status, error, capacity);
        if (d->draining) return gm_error(AVERROR_INVALIDDATA, error, capacity);
        do {
            status = av_read_frame(d->format, d->packet);
            if (status < 0) break;
            if (d->packet->stream_index == d->stream) break;
            av_packet_unref(d->packet);
        } while (1);
        if (status == AVERROR_EOF) {
            d->draining = 1;
            status = avcodec_send_packet(d->codec, NULL);
        } else if (status >= 0) {
            status = avcodec_send_packet(d->codec, d->packet);
            av_packet_unref(d->packet);
        }
        if (status < 0 && status != AVERROR_EOF) return gm_error(status, error, capacity);
    }
}
