#include "GuavaLog.h"
#include "CAndroidHost.h"
#include "Session.h"
#include <android/log.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <stdlib.h>

static JavaVM* guava_vm;
static jclass main_activity;
static jmethodID schedule_diagnostics;
extern jint GuavaSDL_JNI_OnLoad(JavaVM*, void*);
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    guava_vm = vm;
    return GuavaSDL_JNI_OnLoad(vm, reserved);
}

extern void* guava_android_create_application(float scale, const uint16_t* checkpoint, int count,
                                               const uint16_t* configuration, int configuration_count,
                                               const uint16_t* options, int options_count);
extern void guava_android_destroy_application(void* application);
extern void* guava_android_open(void* application, void* window, int width, int height);
extern int guava_android_frame(void* session, uint64_t timestamp);
extern void guava_android_close(void* session);


JNIEXPORT jlong JNICALL Java_com_guava_probe_MainActivity_createApplication(JNIEnv* env, jclass type,
        jfloat scale, jstring resources, jstring checkpoint, jstring configuration, jstring options) {
    if (!main_activity) {
        main_activity = (*env)->NewGlobalRef(env, type);
        schedule_diagnostics = (*env)->GetStaticMethodID(env, type, "scheduleDiagnostics", "(J)V");
        if (!main_activity || !schedule_diagnostics) return 0;
    }
    const char* path = (*env)->GetStringUTFChars(env, resources, NULL);
    if (!path) return 0;
    setenv("PACKAGE_RESOURCE_BUNDLE_PATH", path, 1);
    (*env)->ReleaseStringUTFChars(env, resources, path);
    const jchar* state = (*env)->GetStringChars(env, checkpoint, NULL);
    if (!state) return 0;
    const jchar* launch = (*env)->GetStringChars(env, configuration, NULL);
    if (!launch) { (*env)->ReleaseStringChars(env, checkpoint, state); return 0; }
    const jchar* runtime = (*env)->GetStringChars(env, options, NULL);
    if (!runtime) {
        (*env)->ReleaseStringChars(env, configuration, launch);
        (*env)->ReleaseStringChars(env, checkpoint, state);
        return 0;
    }
    void* application = guava_android_create_application(scale, state, (*env)->GetStringLength(env, checkpoint),
                                                        launch, (*env)->GetStringLength(env, configuration),
                                                        runtime, (*env)->GetStringLength(env, options));
    (*env)->ReleaseStringChars(env, options, runtime);
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

JNIEXPORT jint JNICALL Java_com_guava_probe_MainActivity_frame(JNIEnv* env, jclass type, jlong value, jlong timestamp) {
    (void)env; (void)type;
    GuavaSurface* host = (GuavaSurface*)(uintptr_t)value;
    return host && timestamp >= 0 ? guava_android_frame(host->session, (uint64_t)timestamp) : 0;
}

JNIEXPORT void JNICALL Java_com_guava_probe_MainActivity_close(JNIEnv* env, jclass type, jlong value) {
    (void)env; (void)type;
    GuavaSurface* host = (GuavaSurface*)(uintptr_t)value;
    if (!host) return;
    guava_android_close(host->session);
    ANativeWindow_release(host->window);
    free(host);
}

extern void guava_android_pump_diagnostics(void* application);
JNIEXPORT void JNICALL Java_com_guava_probe_MainActivity_pumpDiagnostics(JNIEnv* env, jclass type, jlong application) {
    (void)env; (void)type;
    guava_android_pump_diagnostics((void*)(uintptr_t)application);
}

void guava_android_schedule_diagnostics(void* application) {
    if (!guava_vm || !main_activity || !schedule_diagnostics) return;
    JNIEnv* env = NULL;
    int attached = (*guava_vm)->GetEnv(guava_vm, (void**)&env, JNI_VERSION_1_6) != JNI_OK;
    if (attached && (*guava_vm)->AttachCurrentThread(guava_vm, &env, NULL) != JNI_OK) return;
    (*env)->CallStaticVoidMethod(env, main_activity, schedule_diagnostics, (jlong)(uintptr_t)application);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); GUAVA_LOG(GUAVA_LOG_ERROR, "com.guava.android.jni", "Diagnostics scheduling failed"); }
    if (attached) (*guava_vm)->DetachCurrentThread(guava_vm);
}

extern void guava_android_log_java(int level, const uint16_t* label, int label_count, const uint16_t* message, int message_count);
JNIEXPORT void JNICALL Java_com_guava_probe_RuntimeLog_write(JNIEnv* env, jclass cls, jint level, jstring label, jstring message) {
    (void)cls;
    if (!label || !message) return;
    // JNI modified UTF-8 encodes surrogate pairs differently; preserve Java's UTF-16 instead.
    const jchar* category = (*env)->GetStringChars(env, label, NULL);
    if (!category) return;
    const jchar* text = (*env)->GetStringChars(env, message, NULL);
    if (text) guava_android_log_java(level, category, (*env)->GetStringLength(env, label), text, (*env)->GetStringLength(env, message));
    (*env)->ReleaseStringChars(env, label, category);
    if (text) (*env)->ReleaseStringChars(env, message, text);
}

JNIEXPORT void JNICALL Java_com_guava_probe_RuntimeLog_flush(JNIEnv* env, jclass cls) { (void)env; (void)cls; guava_log_flush(); }
