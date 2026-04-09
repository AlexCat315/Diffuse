// Citron — Application entry point.
// Uses the guava_shell C ABI to create a native window with CEF OSR + Metal composition.

#import <AppKit/AppKit.h>
#include "citron.h"
#include <cstdio>
#include <cstdlib>

// Callback: messages from JS → native.
static void onJSMessage(const char* json, uint32_t len, void* /*userdata*/) {
    fprintf(stderr, "[Citron] JS message: %.*s\n", (int)len, json);
    // TODO: Route to engine RPC or handle locally.
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        // NSApplication must be initialized before CEF.
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Determine URL: env var for dev, bundled resource for production.
        const char* devUrl = std::getenv("CITRON_DEV_URL");
        const char* url = devUrl ? devUrl : "about:blank";

        // Configure the shell.
        CitronConfig config = {};
        config.width  = 1440;
        config.height = 900;
        config.title  = "Guava Editor";
        config.url    = url;
        config.dev_tools = true;
        config.frameless = false;

        // Default viewport: right 70% of the window.
        config.viewport_x = (int32_t)(config.width * 0.30);
        config.viewport_y = 0;
        config.viewport_w = config.width - config.viewport_x;
        config.viewport_h = config.height;

        CitronShell* shell = citron_create(&config);
        if (!shell) {
            fprintf(stderr, "[Citron] Failed to create shell\n");
            return 1;
        }

        // Register JS message handler.
        citron_on_message(shell, onJSMessage, nullptr);

        // Main loop: process events + CEF + render.
        while (citron_tick(shell)) {
            // Throttle to ~60fps (16.6ms). In production, use CVDisplayLink
            // or CADisplayLink instead of usleep.
            usleep(16000);
        }

        citron_destroy(shell);
    }
    return 0;
}
