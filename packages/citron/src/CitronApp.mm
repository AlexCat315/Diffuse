// Citron — NSApplication delegate.
// Creates the main editor window and wires engine + webview + viewport.
#import "Citron.h"

@implementation CitronApp

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    // Create main editor window (centered, reasonable default size).
    NSRect frame = NSMakeRect(0, 0, 1440, 900);
    _mainWindow = [[EditorWindow alloc] initWithContentRect:frame];
    [_mainWindow center];
    [_mainWindow makeKeyAndOrderFront:nil];

    // Activate the app (bring to front).
    [NSApp activateIgnoringOtherApps:YES];

    // Connect to the engine.
    [_mainWindow.engine connect];

    // Load the React editor UI.
    // In dev mode, load from Vite dev server; in production, load from bundle.
    NSString* devURL = [[NSProcessInfo processInfo].environment objectForKey:@"CITRON_DEV_URL"];
    if (devURL) {
        [_mainWindow.webBridge loadURL:[NSURL URLWithString:devURL]];
    } else {
        // Production: load from app bundle Resources/web/index.html
        NSString* webPath = [[NSBundle mainBundle] pathForResource:@"index"
                                                            ofType:@"html"
                                                       inDirectory:@"web"];
        if (webPath) {
            [_mainWindow.webBridge loadURL:[NSURL fileURLWithPath:webPath]];
        } else {
            NSLog(@"[Citron] ERROR: No web bundle found. Set CITRON_DEV_URL for dev mode.");
        }
    }

    // Set up main menu.
    [self setupMainMenu];
}

- (void)setupMainMenu {
    NSMenu* mainMenu = [[NSMenu alloc] init];

    // App menu
    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Citron"];
    [appMenu addItemWithTitle:@"About Citron" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Citron" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];
    [mainMenu addItem:appMenuItem];

    // Edit menu (for standard key bindings: copy, paste, etc.)
    NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];
    [mainMenu addItem:editMenuItem];

    // View menu
    NSMenuItem* viewMenuItem = [[NSMenuItem alloc] init];
    NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    [viewMenu addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    [viewMenuItem setSubmenu:viewMenu];
    [mainMenu addItem:viewMenuItem];

    [NSApp setMainMenu:mainMenu];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    [_mainWindow.engine disconnect];
    [_mainWindow.viewport detach];
}

@end
