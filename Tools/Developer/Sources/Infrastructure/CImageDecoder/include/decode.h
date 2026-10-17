#ifndef GUAVA_TOOL_IMAGE_DECODE_H
#define GUAVA_TOOL_IMAGE_DECODE_H

unsigned char *guava_tool_decode_image(const unsigned char *data, int count, int *width, int *height);
void guava_tool_free_image(unsigned char *pixels);

#endif
