#include "Session.h"
#include <jni.h>
#include <stdlib.h>

extern void cove_android_pointer(void* session, int kind, float x, float y);
extern void cove_android_text(void* session, const uint16_t* text, int count, int composing);
extern void cove_android_key(void* session, uint32_t scancode, uint16_t modifiers);
extern void cove_android_scroll(void* session, float x, float y, float dx, float dy);
extern void cove_android_key_state(void* session, uint32_t scancode, int down);
extern int cove_android_snapshot(void* session, uint16_t* output, int capacity);
extern int cove_android_input_snapshot(void* session, uint16_t* output, int capacity);
extern void cove_android_edit(void* session, int kind, int start, int end);

JNIEXPORT void JNICALL Java_com_cove_probe_MainActivity_pointer(JNIEnv* env, jclass type, jlong value, jint kind, jfloat x, jfloat y) {
    (void)env; (void)type;
    CoveSurface* host = (CoveSurface*)(uintptr_t)value;
    if (host) cove_android_pointer(host->session, kind, x, y);
}

JNIEXPORT void JNICALL Java_com_cove_probe_MainActivity_text(JNIEnv* env, jclass type, jlong value, jstring text, jboolean composing) {
    (void)type;
    CoveSurface* host = (CoveSurface*)(uintptr_t)value;
    if (!host) return;
    const jchar* units = (*env)->GetStringChars(env, text, NULL);
    if (!units) return;
    cove_android_text(host->session, units, (*env)->GetStringLength(env, text), composing);
    (*env)->ReleaseStringChars(env, text, units);
}

JNIEXPORT void JNICALL Java_com_cove_probe_MainActivity_key(JNIEnv* env, jclass type, jlong value, jint scancode, jint modifiers) {
    (void)env; (void)type;
    CoveSurface* host = (CoveSurface*)(uintptr_t)value;
    if (host) cove_android_key(host->session, scancode, (uint16_t)modifiers);
}

JNIEXPORT void JNICALL Java_com_cove_probe_MainActivity_scroll(JNIEnv* env, jclass type, jlong value, jfloat x, jfloat y, jfloat dx, jfloat dy) {
    (void)env; (void)type;
    CoveSurface* host = (CoveSurface*)(uintptr_t)value;
    if (host) cove_android_scroll(host->session, x, y, dx, dy);
}

static jstring copy_snapshot(JNIEnv* env, CoveSurface* host, int (*copy)(void*, uint16_t*, int)) {
    if (!host) return (*env)->NewStringUTF(env, "{}");
    int count = copy(host->session, NULL, 0);
    if (count <= 0 || count > 1024 * 1024) return NULL;
    uint16_t* units = malloc((size_t)count * sizeof(uint16_t));
    if (!units) return NULL;
    int written = copy(host->session, units, count);
    jstring result = written >= 0 && written <= count ? (*env)->NewString(env, units, written) : NULL;
    free(units);
    return result;
}

JNIEXPORT jstring JNICALL Java_com_cove_probe_MainActivity_snapshot(JNIEnv* env, jclass type, jlong value) {
    (void)type;
    return copy_snapshot(env, (CoveSurface*)(uintptr_t)value, cove_android_snapshot);
}

JNIEXPORT jstring JNICALL Java_com_cove_probe_MainActivity_inputSnapshot(JNIEnv* env, jclass type, jlong value) {
    (void)type;
    return copy_snapshot(env, (CoveSurface*)(uintptr_t)value, cove_android_input_snapshot);
}

JNIEXPORT void JNICALL Java_com_cove_probe_MainActivity_keyState(JNIEnv* env, jclass type, jlong value, jint scancode, jboolean down) {
    (void)env; (void)type;
    CoveSurface* host = (CoveSurface*)(uintptr_t)value;
    if (host) cove_android_key_state(host->session, scancode, down);
}

JNIEXPORT void JNICALL Java_com_cove_probe_MainActivity_edit(JNIEnv* env, jclass type, jlong value, jint kind, jint start, jint end) {
    (void)env; (void)type;
    CoveSurface* host = (CoveSurface*)(uintptr_t)value;
    if (host) cove_android_edit(host->session, kind, start, end);
}
