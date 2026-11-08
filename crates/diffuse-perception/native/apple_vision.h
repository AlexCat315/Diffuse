#ifndef DIFFUSE_APPLE_VISION_H
#define DIFFUSE_APPLE_VISION_H

#include <stdbool.h>
#include <stddef.h>

typedef struct {
    char *identifier;
    double confidence;
} DiffuseVisionClassification;

bool diffuse_vision_classify(const char *path,
                             int max_results,
                             DiffuseVisionClassification **items,
                             size_t *count,
                             char **error_message);
void diffuse_vision_free_classifications(DiffuseVisionClassification *items, size_t count);
void diffuse_vision_free_string(char *text);

#endif
