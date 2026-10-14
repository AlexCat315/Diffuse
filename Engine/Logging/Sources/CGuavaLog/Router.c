#include "GuavaLog.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
static SRWLOCK router_lock = SRWLOCK_INIT;
#define LOCK() AcquireSRWLockExclusive(&router_lock)
#define UNLOCK() ReleaseSRWLockExclusive(&router_lock)
#elif defined(__wasi__)
#define LOCK() ((void)0)
#define UNLOCK() ((void)0)
#else
#include <pthread.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
static pthread_mutex_t router_lock = PTHREAD_MUTEX_INITIALIZER;
#define LOCK() pthread_mutex_lock(&router_lock)
#define UNLOCK() pthread_mutex_unlock(&router_lock)
#endif
#ifdef __ANDROID__
#include <android/log.h>
#endif
static GuavaLogCallback callback;
static GuavaLogFlushCallback flush_callback;
void guava_log_set_handler(GuavaLogCallback handler, GuavaLogFlushCallback flush) { LOCK(); callback = handler; flush_callback = flush; UNLOCK(); }
void guava_log_flush(void) { LOCK(); GuavaLogFlushCallback flush = flush_callback; UNLOCK(); if (flush) flush(); }
void guava_log_write(int32_t level, const char *label, const char *message,
                     const char *file, const char *function, uint32_t line) {
    LOCK(); GuavaLogCallback handler = callback; UNLOCK();
    if (handler) handler(level, label, message, file, function, line);
    else guava_log_console_write(level, message ? message : "");
}
void guava_log_console_write(int32_t level, const char *message) {
    if (!message) return;
    LOCK();
#ifdef __ANDROID__
    static const int priorities[] = {ANDROID_LOG_VERBOSE, ANDROID_LOG_DEBUG, ANDROID_LOG_INFO,
        ANDROID_LOG_INFO, ANDROID_LOG_WARN, ANDROID_LOG_ERROR, ANDROID_LOG_FATAL};
    int priority = priorities[level >= 0 && level <= 6 ? level : 2];
    size_t length = strlen(message), offset = 0;
    do {
        size_t count = length - offset > 3800 ? 3800 : length - offset;
        while (offset + count < length && count && (((unsigned char)message[offset + count] & 0xc0) == 0x80)) count--;
        char chunk[3801]; memcpy(chunk, message + offset, count); chunk[count] = 0;
        __android_log_write(priority, "Guava", chunk); offset += count;
    } while (offset < length);
#else
    (void)level; fputs(message, stderr); fputc('\n', stderr); fflush(stderr);
#endif
    UNLOCK();
}
intptr_t guava_log_lock_file(const char *path) {
#ifdef _WIN32
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!length) return -1;
    wchar_t *wide = (wchar_t *)malloc((size_t)length * sizeof(wchar_t));
    if (!wide) return -1;
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, length);
    HANDLE h = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wide);
    if (h == INVALID_HANDLE_VALUE) return -1;
    OVERLAPPED range = {0};
    if (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &range)) { CloseHandle(h); return -1; }
    return (intptr_t)h;
#elif defined(__wasi__)
    (void)path; return -1;
#else
    int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return -1; }
    return fd;
#endif
}
void guava_log_unlock_file(intptr_t handle) {
#ifdef _WIN32
    if (handle != -1) CloseHandle((HANDLE)handle);
#elif !defined(__wasi__)
    if (handle >= 0) { flock((int)handle, LOCK_UN); close((int)handle); }
#else
    (void)handle;
#endif
}

void guava_log_printf(int32_t level, const char *label, const char *file, const char *function, uint32_t line, const char *format, ...) {
    char message[4096]; va_list arguments; va_start(arguments, format);
    vsnprintf(message, sizeof(message), format, arguments); va_end(arguments);
    guava_log_write(level, label, message, file, function, line);
}
