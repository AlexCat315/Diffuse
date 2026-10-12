#include "CAndroidHost.h"
#include "Session.h"
#include <android/log.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <stdlib.h>

extern jint GuavaSDL_JNI_OnLoad(JavaVM*, void*);
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    return GuavaSDL_JNI_OnLoad(vm, reserved);
}

extern void* guava_android_create_application(float scale, const uint16_t* checkpoint, int count,
                                               const uint16_t* configuration, int configuration_count);
extern void guava_android_destroy_application(void* application);
extern void* guava_android_open(void* application, void* window, int width, int height);
extern int guava_android_frame(void* session);
extern void guava_android_close(void* session);

void guava_android_log(const char* message) { __android_log_write(ANDROID_LOG_INFO, "GuavaAndroid", message); }

JNIEXPORT jlong JNICALL Java_com_guava_probe_MainActivity_createApplication(JNIEnv* env, jclass type,
        jfloat scale, jstring resources, jstring checkpoint, jstring configuration) {
    (void)type;
    const char* path = (*env)->GetStringUTFChars(env, resources, NULL);
    if (!path) return 0;
    setenv("PACKAGE_RESOURCE_BUNDLE_PATH", path, 1);
    (*env)->ReleaseStringUTFChars(env, resources, path);
    const jchar* state = (*env)->GetStringChars(env, checkpoint, NULL);
    if (!state) return 0;
    const jchar* launch = (*env)->GetStringChars(env, configuration, NULL);
    if (!launch) { (*env)->ReleaseStringChars(env, checkpoint, state); return 0; }
    void* application = guava_android_create_application(scale, state, (*env)->GetStringLength(env, checkpoint),
                                                        launch, (*env)->GetStringLength(env, configuration));
    (*env)->ReleaseStringChars(env, configuration, launch);
    (*env)->ReleaseStringChars(env, checkpoint, state);
    return (jlong)(uintptr_t)application;
}

JNIEXPORT void JNICALL Java_com_guava_probe_MainActivity_destroyApplication(JNIEnv* env, jclass type, jlong value) {
    (void)env; (void)type;
    guava_android_destroy_application((void*)(uintptr_t)value);
}

JNIEXPORT jlong JNICALL Java_com_guava_probe_MainActivity_open(JNIEnv* env, jclass type, jlong application,
        jobject surface, jint width, jint height) {
    (void)type;
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    if (!window) return 0;
    void* session = guava_android_open((void*)(uintptr_t)application, window, width, height);
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
