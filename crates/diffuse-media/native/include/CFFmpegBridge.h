#ifndef COVE_MEDIA_BRIDGE_H
#define COVE_MEDIA_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

typedef struct GMDecoder GMDecoder;
typedef struct {
    double duration;
    int width, height;
    int sample_rate, channels;
} GMStreamInfo;

// Local files only. Each decoder owns an independent demuxer and codec context.
GMDecoder *gm_open(const char *path, int video, char *error, size_t capacity);
void gm_close(GMDecoder *decoder);
GMStreamInfo gm_info(const GMDecoder *decoder);
int gm_seek(GMDecoder *decoder, double seconds, char *error, size_t capacity);
// 1 = frame, 0 = EOF, -1 = error. Storage is valid until the next read/seek/close.
int gm_read_audio(GMDecoder *decoder, const float **samples, int *frames, char *error, size_t capacity);
int gm_read_video(GMDecoder *decoder, const uint8_t **rgba, int *stride, double *seconds, char *error, size_t capacity);
#endif
