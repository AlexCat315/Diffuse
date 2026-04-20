#ifndef GUAVA_STB_IMAGE_WRITE_H
#define GUAVA_STB_IMAGE_WRITE_H

#include <stb_image_write.h>

/* stbi_write_png_to_mem is defined in the implementation section of stb_image_write.h.
   Declare it here so translate-c exposes it to Zig code. */
unsigned char *stbi_write_png_to_mem(const unsigned char *pixels, int stride_bytes,
                                      int x, int y, int n, int *out_len);

#endif