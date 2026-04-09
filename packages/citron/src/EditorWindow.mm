// Citron — Main editor window with NSSplitView layout.
// Left: WKWebView (React UI panels)  |  Right: MetalViewport (3D scene)
#import "Citron.h"

@interface EditorWindow ()
@property (nonatomic, strong) NSSplitView* splitView;
@end

@implementation EditorWindow

- (instancetype)initWithContentRect:(NSRect)contentRect {
    self = [super initWithContentRect:contentRect
                            styleMask:(NSWindowStyleMaskTitled |
                                       NSWindowStyleMaskClosable |
                                       NSWindowStyleMaskMiniaturizable |
                                       NSWindowStyleMaskResizable)
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (!self) return nil;

    self.title = @"Guava Editor";
    self.minSize = NSMakeSize(800, 600);
    self.backgroundColor = [NSColor colorWithRed:0.118 green:0.118 blue:0.180 alpha:1.0]; // #1e1e2e

    // ── Create components ────────────────────────────────────────────────
    _engine = [[EngineClient alloc] init];
    _webBridge = [[WebViewBridge alloc] initWithFrame:NSMakeRect(0, 0, 400, contentRect.size.height)];
    _viewport = [[MetalViewport alloc] initWithFrame:NSMakeRect(0, 0, contentRect.size.width - 400, contentRect.size.height)];

    // ── NSSplitView: WebView | Viewport ──────────────────────────────────
    _splitView = [[NSSplitView alloc] initWithFrame:contentRect];
    _splitView.vertical = YES;  // horizontal split (left | right)
    _splitView.dividerStyle = NSSplitViewDividerStyleThin;
    _splitView.delegate = self;
    _splitView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [_splitView addSubview:_webBridge.webView];
    [_splitView addSubview:_viewport];

    // Set initial split position (~30% for web, 70% for viewport).
    [_splitView setPosition:contentRect.size.width * 0.3
           ofDividerAtIndex:0];

    self.contentView = _splitView;

    // ── Wire up engine ↔ webview ↔ viewport ──────────────────────────────
    [self setupMessageRouting];

    return self;
}

// ── NSSplitView Delegate ─────────────────────────────────────────────────

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMinCoordinate:(CGFloat)proposedMin
         ofSubviewAt:(NSInteger)dividerIndex {
    return 200;  // Minimum 200pt for webview
}

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMaxCoordinate:(CGFloat)proposedMax
         ofSubviewAt:(NSInteger)dividerIndex {
    return splitView.frame.size.width - 300;  // Minimum 300pt for viewport
}

// ── Message Routing ──────────────────────────────────────────────────────
// JS sends messages via window.citron.postMessage({method, id?, params}).
// Native routes them to the appropriate handler (engine RPC, viewport, fs, etc).

- (void)setupMessageRouting {
    __weak EditorWindow* weakSelf = self;

    [_webBridge setMessageHandler:^(NSDictionary* body) {
        EditorWindow* self = weakSelf;
        if (!self) return;

        NSString* method = body[@"method"];
        NSDictionary* params = body[@"params"];
        NSNumber* requestId = body[@"id"];

        if (!method) return;

        // ── Viewport commands ────────────────────────────────────────────
        if ([method isEqualToString:@"viewport:attachSurface"]) {
            uint32_t surfaceId = [params[@"surfaceId"] unsignedIntValue];
            [self.viewport attachSurface:surfaceId];
            if (requestId) {
                [self.webBridge sendToJS:@{@"id": requestId, @"result": @{@"ok": @YES}}];
            }
            return;
        }

        if ([method isEqualToString:@"viewport:updateSurface"]) {
            uint32_t surfaceId = [params[@"surfaceId"] unsignedIntValue];
            [self.viewport updateSurface:surfaceId];
            if (requestId) {
                [self.webBridge sendToJS:@{@"id": requestId, @"result": @{@"ok": @YES}}];
            }
            return;
        }

        if ([method isEqualToString:@"viewport:detach"]) {
            [self.viewport detach];
            if (requestId) {
                [self.webBridge sendToJS:@{@"id": requestId, @"result": @{@"ok": @YES}}];
            }
            return;
        }

        // ── Engine RPC passthrough ───────────────────────────────────────
        if ([method hasPrefix:@"engine:"]) {
            NSString* rpcMethod = [method substringFromIndex:7]; // strip "engine:"
            [self.engine call:rpcMethod params:params completion:^(NSDictionary* result, NSError* error) {
                if (requestId) {
                    if (error) {
                        [self.webBridge sendToJS:@{
                            @"id": requestId,
                            @"error": @{@"message": error.localizedDescription}
                        }];
                    } else {
                        [self.webBridge sendToJS:@{
                            @"id": requestId,
                            @"result": result ?: @{}
                        }];
                    }
                }
            }];
            return;
        }

        // ── File system operations ───────────────────────────────────────
        if ([method hasPrefix:@"fs:"]) {
            [self handleFileSystemMessage:method params:params requestId:requestId];
            return;
        }

        NSLog(@"[Citron] Unknown message method: %@", method);
    }];

    // Forward engine notifications to JS.
    [_engine onNotification:@"*" handler:^(NSDictionary* notification) {
        [weakSelf.webBridge sendToJS:@{
            @"type": @"notification",
            @"method": notification[@"method"] ?: @"",
            @"params": notification[@"params"] ?: @{}
        }];
    }];
}

// ── File System Handlers (placeholder) ───────────────────────────────────

- (void)handleFileSystemMessage:(NSString*)method
                         params:(NSDictionary*)params
                      requestId:(NSNumber*)requestId {
    // TODO: Implement fs:mkdir, fs:readFile, fs:writeFile, fs:delete, etc.
    NSLog(@"[Citron] fs handler not yet implemented: %@", method);
    if (requestId) {
        [self.webBridge sendToJS:@{
            @"id": requestId,
            @"error": @{@"message": @"Not yet implemented"}
        }];
    }
}

@end
