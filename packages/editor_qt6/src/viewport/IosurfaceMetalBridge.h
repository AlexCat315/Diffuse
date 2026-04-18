#pragma once

#include <QtGlobal>

void *guava_create_metal_texture_from_iosurface(
    void *metalDevice,
    quint32 surfaceId,
    int width,
    int height);

void guava_release_metal_texture(void *metalTexture);
