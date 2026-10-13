#pragma once
#include <android/native_window.h>
#include <stdint.h>

typedef struct {
    ANativeWindow* window;
    void* session;
} GuavaSurface;
