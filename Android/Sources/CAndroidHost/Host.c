#include "CAndroidHost.h"
#include "Session.h"
#include <android/log.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <stdlib.h>

extern void* guava_android_open(void* window, int width, int height, float scale, const uint16_t* checkpoint, int count);
extern int guava_android_frame(void* session);
extern void guava_android_close(void* session);

void guava_android_log(const char* message) { __android_log_write(ANDROID_LOG_INFO, "GuavaAndroid", message); }

JNIEXPORT jlong JNICALL Java_com_guava_probe_MainActivity_open(JNIEnv* env, jclass type, jobject surface,
                                                               jint width, jint height, jfloat scale, jstring resources, jstring checkpoint) {
    (void)type;
    const char* path = (*env)->GetStringUTFChars(env, resources, NULL);
    if (!path) return 0;
    setenv("PACKAGE_RESOURCE_BUNDLE_PATH", path, 1);
    (*env)->ReleaseStringUTFChars(env, resources, path);
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    if (!window) return 0;
    const jchar* state = (*env)->GetStringChars(env, checkpoint, NULL);
    if (!state) { ANativeWindow_release(window); return 0; }
    void* session = guava_android_open(window, width, height, scale, state, (*env)->GetStringLength(env, checkpoint));
    (*env)->ReleaseStringChars(env, checkpoint, state);
    if (!session) { ANativeWindow_release(window); return 0; }
    GuavaSurface* host = calloc(1, sizeof(GuavaSurface));
    if (!host) { guava_android_close(session); ANativeWindow_release(window); return 0; }
    host->window = window; host->session = session;
    return (jlong)(uintptr_t)host;
}

JNIEXPORT jint JNICALL Java_com_guava_probe_MainActivity_frame(JNIEnv* env, jclass type, jlong value) {
    (void)env; (void)type;
    GuavaSurface* host = (GuavaSurface*)(uintptr_t)value;
    return host ? guava_android_frame(host->session) : 0;
}

JNIEXPORT void JNICALL Java_com_guava_probe_MainActivity_close(JNIEnv* env, jclass type, jlong value) {
    (void)env; (void)type;
    GuavaSurface* host = (GuavaSurface*)(uintptr_t)value;
    if (!host) return;
    guava_android_close(host->session);
    ANativeWindow_release(host->window);
    free(host);
}
