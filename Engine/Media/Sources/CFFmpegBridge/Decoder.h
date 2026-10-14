#include "CFFmpegBridge.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

struct GMDecoder {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVPacket *packet;
    AVFrame *frame;
    int stream;
    int draining;
    double seek_time;
    SwrContext *resampler;
    struct SwsContext *scaler;
    uint8_t *output;
    unsigned int output_size;
};
int gm_error(int code, char *error, size_t capacity);
int gm_next_frame(GMDecoder *decoder, char *error, size_t capacity);
double gm_frame_time(GMDecoder *decoder);
