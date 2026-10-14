#include "sdl3_shim.h"
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

// SDL's main callback has no userdata parameter. This state is private to the
// single application entry and is cleared when the lifecycle returns.
static GuavaSDLAppMain app_entry;
static void *app_context;
static int guava_sdl_app_main(int argc, char **argv) {
    (void)argc; (void)argv;
    return app_entry(app_context);
}
int guava_sdl_run_app(GuavaSDLAppMain entry, void *context) {
    if (!entry || app_entry) return -1;
    app_entry = entry;
    app_context = context;
    int result = SDL_RunApp(0, NULL, guava_sdl_app_main, NULL);
    app_entry = NULL;
    app_context = NULL;
    return result;
}
