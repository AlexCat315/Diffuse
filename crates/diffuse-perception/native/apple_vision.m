#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#include "apple_vision.h"
#include <stdlib.h>
#include <string.h>

static char *copy_string(const char *text) {
    if (!text) return NULL;
    size_t length = strlen(text) + 1;
    char *copy = malloc(length);
    if (copy) memcpy(copy, text, length);
    return copy;
}

bool diffuse_vision_classify(const char *path,
                             int max_results,
                             DiffuseVisionClassification **items,
                             size_t *count,
                             char **error_message) {
    if (!items || !count) return false;
    *items = NULL;
    *count = 0;
    if (error_message) *error_message = NULL;
    if (!path) {
        if (error_message) *error_message = copy_string("invalid image path");
        return false;
    }

    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        VNClassifyImageRequest *request = [[VNClassifyImageRequest alloc] init];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithURL:url options:@{}];
        NSError *error = nil;
        if (![handler performRequests:@[request] error:&error]) {
            NSString *message = error.localizedDescription ?: @"Vision request failed";
            if (error_message) *error_message = copy_string(message.UTF8String);
            return false;
        }

        NSArray<VNClassificationObservation *> *results = request.results ?: @[];
        NSUInteger limit = (NSUInteger)(max_results > 1 ? max_results : 1);
        size_t total = results.count < limit ? (size_t)results.count : (size_t)limit;
        if (total == 0) return true;

        DiffuseVisionClassification *entries = calloc(total, sizeof(DiffuseVisionClassification));
        if (!entries) {
            if (error_message) *error_message = copy_string("could not allocate classification results");
            return false;
        }
        size_t index = 0;
        for (VNClassificationObservation *observation in results) {
            if (index >= total) break;
            entries[index].identifier = copy_string(observation.identifier.UTF8String);
            entries[index].confidence = (double)observation.confidence;
            index += 1;
        }
        *items = entries;
        *count = total;
        return true;
    }
}

void diffuse_vision_free_classifications(DiffuseVisionClassification *items, size_t count) {
    if (!items) return;
    for (size_t index = 0; index < count; index += 1) {
        free(items[index].identifier);
    }
    free(items);
}

void diffuse_vision_free_string(char *text) {
    free(text);
}
