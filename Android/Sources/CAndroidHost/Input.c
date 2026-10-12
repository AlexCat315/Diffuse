#include "Session.h"
#include <jni.h>
#include <stdlib.h>

extern void guava_android_pointer(void* session, int kind, float x, float y);
extern void guava_android_text(void* session, const uint16_t* text, int count, int composing);
extern void guava_android_key(void* session, uint32_t scancode);
extern int guava_android_snapshot(void* session, uint16_t* output, int capacity);

JNIEXPORT void JNICALL Java_com_guava_probe_MainActivity_pointer(JNIEnv* env, jclass type, jlong value, jint kind, jfloat x, jfloat y) {
    (void)env; (void)type;
    GuavaSurface* host = (GuavaSurface*)(uintptr_t)value;
    if (host) guava_android_pointer(host->session, kind, x, y);
}

JNIEXPORT void JNICALL Java_com_guava_probe_MainActivity_text(JNIEnv* env, jclass type, jlong value, jstring text, jboolean composing) {
    (void)type;
    GuavaSurface* host = (GuavaSurface*)(uintptr_t)value;
    if (!host) return;
    const jchar* units = (*env)->GetStringChars(env, text, NULL);
    if (!units) return;
    guava_android_text(host->session, units, (*env)->GetStringLength(env, text), composing);
    (*env)->ReleaseStringChars(env, text, units);
}

JNIEXPORT void JNICALL Java_com_guava_probe_MainActivity_key(JNIEnv* env, jclass type, jlong value, jint scancode) {
    (void)env; (void)type;
    GuavaSurface* host = (GuavaSurface*)(uintptr_t)value;
    if (host) guava_android_key(host->session, scancode);
}

JNIEXPORT jstring JNICALL Java_com_guava_probe_MainActivity_snapshot(JNIEnv* env, jclass type, jlong value) {
    (void)type;
    GuavaSurface* host = (GuavaSurface*)(uintptr_t)value;
    if (!host) return (*env)->NewStringUTF(env, "{}");
    int count = guava_android_snapshot(host->session, NULL, 0);
    if (count <= 0 || count > 1024 * 1024) return NULL;
    uint16_t* units = malloc((size_t)count * sizeof(uint16_t));
    if (!units) return NULL;
    guava_android_snapshot(host->session, units, count);
    jstring result = (*env)->NewString(env, units, count);
    free(units);
    return result;
}
