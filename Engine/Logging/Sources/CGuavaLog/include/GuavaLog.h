#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef enum { GUAVA_LOG_TRACE, GUAVA_LOG_DEBUG, GUAVA_LOG_INFO, GUAVA_LOG_NOTICE,
    GUAVA_LOG_WARNING, GUAVA_LOG_ERROR, GUAVA_LOG_CRITICAL } GuavaLogLevel;
typedef void (*GuavaLogCallback)(int32_t level, const char *label, const char *message,
    const char *file, const char *function, uint32_t line);
typedef void (*GuavaLogFlushCallback)(void);
void guava_log_set_handler(GuavaLogCallback handler, GuavaLogFlushCallback flush);
void guava_log_flush(void);
void guava_log_write(int32_t level, const char *label, const char *message,
    const char *file, const char *function, uint32_t line);
void guava_log_printf(int32_t level, const char *label, const char *file, const char *function, uint32_t line, const char *format, ...);
void guava_log_console_write(int32_t level, const char *message);
intptr_t guava_log_lock_file(const char *path);
void guava_log_unlock_file(intptr_t handle);
#define GUAVA_LOGF(level, label, ...) guava_log_printf(level, label, __FILE__, __func__, __LINE__, __VA_ARGS__)
#define GUAVA_LOG(level, label, message) guava_log_write(level, label, message, __FILE__, __func__, __LINE__)
#ifdef __cplusplus
}
#endif
