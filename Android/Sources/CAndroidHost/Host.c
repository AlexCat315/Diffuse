#include "CAndroidHost.h"
#include <android/log.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <stdlib.h>

extern void* guava_android_open(void* window, int width, int height);
extern void guava_android_draw(void* session, float x, float y);
extern void guava_android_close(void* session);

typedef struct {
    ANativeWindow* window;
    void* session;
} GuavaSurface;

void guava_android_log(const char* message) { __android_log_write(ANDROID_LOG_INFO, "GuavaAndroid", message); }

JNIEXPORT jlong JNICALL Java_com_guava_probe_MainActivity_open(JNIEnv* env, jclass type, jobject surface,
                                                               jint width, jint height, jstring resources) {
    (void)type;
    const char* path = (*env)->GetStringUTFChars(env, resources, NULL);
    setenv("PACKAGE_RESOURCE_BUNDLE_PATH", path, 1);
    (*env)->ReleaseStringUTFChars(env, resources, path);
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    if (!window) return 0;
    void* session = guava_android_open(window, width, height);
    if (!session) { ANativeWindow_release(window); return 0; }
    GuavaSurface* host = calloc(1, sizeof(GuavaSurface));
    if (!host) { guava_android_close(session); ANativeWindow_release(window); return 0; }
    host->window = window; host->session = session;
    return (jlong)(uintptr_t)host;
}

JNIEXPORT void JNICALL Java_com_guava_probe_MainActivity_draw(JNIEnv* env, jclass type, jlong value, jfloat x, jfloat y) {
    (void)env; (void)type;
    GuavaSurface* host = (GuavaSurface*)(uintptr_t)value;
    if (host) guava_android_draw(host->session, x, y);
}

JNIEXPORT void JNICALL Java_com_guava_probe_MainActivity_close(JNIEnv* env, jclass type, jlong value) {
    (void)env; (void)type;
    GuavaSurface* host = (GuavaSurface*)(uintptr_t)value;
    if (!host) return;
    guava_android_close(host->session);
    ANativeWindow_release(host->window);
    free(host);
}
