#include "MacOS.h"

#include <AppKit/AppKit.h>

uint64_t getQtWidgetNSView(quintptr qtWinId)
{
    // qtWinId on macOS is typically a pointer to the native window handle.
    // We need to extract the actual NSView from it and verify it has a window.
    
    NSView* view = reinterpret_cast<NSView*>(qtWinId);
    
    @try {
        // Soft validation: check if it looks like a valid NSView
        if (!view) {
            NSLog(@"[Guava] NSView pointer is NULL");
            return 0;
        }

        // Try to call a simple method to validate it's really an NSView
        if (![view isKindOfClass:[NSView class]]) {
            NSLog(@"[Guava] Pointer is not an NSView");
            return 0;
        }

        // Get the window
        NSWindow* window = [view window];
        if (!window) {
            NSLog(@"[Guava] NSView has no associated NSWindow");
            return 0;
        }

        // Try to actually use the window to verify it's valid
        NSString* windowTitle = [window title];
        if (!windowTitle) windowTitle = @"(untitled)";

        uint64_t result = reinterpret_cast<uint64_t>(view);
        NSLog(@"[Guava] Qt NSView: %p (window: '%@', level=%ld, frame=%@)",
              view, windowTitle, window.level, NSStringFromRect(window.frame));
        return result;
    } @catch (NSException* e) {
        NSLog(@"[Guava] Exception validating NSView: %@ — %@", e.name, e.reason);
        return 0;
    }
}
