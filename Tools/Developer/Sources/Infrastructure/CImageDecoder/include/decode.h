#ifndef COVE_TOOL_IMAGE_DECODE_H
#define COVE_TOOL_IMAGE_DECODE_H

unsigned char *cove_tool_decode_image(const unsigned char *data, int count, int *width, int *height);
void cove_tool_free_image(unsigned char *pixels);

#endif
