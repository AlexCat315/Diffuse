#include <stddef.h>

void *openmpt_module_create_from_memory(const void *filedata, size_t filesize, void *logfunc, void *user, void *ctls) {
    (void)filedata;
    (void)filesize;
    (void)logfunc;
    (void)user;
    (void)ctls;
    return NULL;
}

void openmpt_module_destroy(void *mod) {
    (void)mod;
}

int openmpt_module_read_float_stereo(void *mod, int samplerate, size_t count, float *left, float *right) {
    (void)mod;
    (void)samplerate;
    (void)count;
    (void)left;
    (void)right;
    return 0;
}

void openmpt_module_set_repeat_count(void *mod, int repeat_count) {
    (void)mod;
    (void)repeat_count;
}