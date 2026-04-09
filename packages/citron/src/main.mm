// Citron — Guava Editor application entry point.
// The application layer: connects Citron shell (CEF UI) with the Guava engine (WebSocket RPC).

#import <AppKit/AppKit.h>
#include "citron.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

// ── Engine WebSocket RPC Client ──────────────────────────────────────────

static NSString* const kEngineURL = @"ws://127.0.0.1:9100";

@interface EngineRPC : NSObject <NSURLSessionWebSocketDelegate>
@property (nonatomic) BOOL connected;
@property (nonatomic) CitronShell* shell;
- (void)connect;
- (void)disconnect;
- (void)sendRaw:(NSString*)jsonString;
@end

@implementation EngineRPC {
    NSURLSessionWebSocketTask* _wsTask;
    NSURLSession* _session;
    BOOL _shouldReconnect;
}

- (instancetype)initWithShell:(CitronShell*)shell {
    self = [super init];
    if (!self) return nil;
    _shell = shell;
    _shouldReconnect = NO;
    _connected = NO;
    _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                             delegate:self
                                        delegateQueue:[NSOperationQueue mainQueue]];
    return self;
}

- (void)connect {
    _shouldReconnect = YES;
    [self doConnect];
}

- (void)doConnect {
    if (_wsTask) return;
    NSURL* url = [NSURL URLWithString:kEngineURL];
    _wsTask = [_session webSocketTaskWithURL:url];
    [_wsTask resume];
    [self listenForMessages];
    NSLog(@"[Guava/Engine] Connecting to %@...", kEngineURL);
}

- (void)disconnect {
    _shouldReconnect = NO;
    _connected = NO;
    [_wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    _wsTask = nil;
}

- (void)scheduleReconnect {
    if (!_shouldReconnect) return;
    _wsTask = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (self->_shouldReconnect && !self->_wsTask) {
            [self doConnect];
        }
    });
}

- (void)listenForMessages {
    __weak EngineRPC* weakSelf = self;
    [_wsTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage* msg, NSError* error) {
        EngineRPC* self = weakSelf;
        if (!self) return;
        if (error) {
            NSLog(@"[Guava/Engine] WS error: %@", error.localizedDescription);
            self->_connected = NO;
            [self scheduleReconnect];
            return;
        }
        if (msg.type == NSURLSessionWebSocketMessageTypeString) {
            [self handleMessage:msg.string];
        }
        [self listenForMessages];
    }];
}

- (void)handleMessage:(NSString*)jsonString {
    NSData* data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

    // Intercept surfaceId from engine responses (viewport.getSurfaceId).
    if (json && json[@"result"]) {
        NSDictionary* result = json[@"result"];
        if ([result isKindOfClass:[NSDictionary class]] && result[@"surfaceId"]) {
            uint32_t surfaceId = [result[@"surfaceId"] unsignedIntValue];
            if (surfaceId > 0 && _shell) {
                NSLog(@"[Guava/Engine] Got scene surface: %u", surfaceId);
                citron_set_scene_surface(_shell, surfaceId);
            }
        }
    }

    // Forward engine response/event to JS — the preload bridge handles dispatch.
    // Engine push events come as: { "method": "on:xxx", "params": {...} }
    // Engine RPC responses come as: { "jsonrpc": "2.0", "id": N, "result": {...} }
    if (json[@"method"] && !json[@"id"]) {
        // Engine push event → wrap as engine.event for the preload bridge.
        NSString* method = json[@"method"];
        id params = json[@"params"] ?: [NSNull null];
        NSDictionary* eventMsg = @{
            @"type": @"engine.event",
            @"event": method,
            @"data": params
        };
        NSData* eventData = [NSJSONSerialization dataWithJSONObject:eventMsg options:0 error:nil];
        if (eventData && _shell) {
            NSString* eventStr = [[NSString alloc] initWithData:eventData encoding:NSUTF8StringEncoding];
            const char* cstr = [eventStr UTF8String];
            citron_send_to_js(_shell, cstr, (uint32_t)strlen(cstr));
        }
    } else if (_shell) {
        // JSON-RPC response (has id + result/error) — pass through directly.
        const char* cstr = [jsonString UTF8String];
        citron_send_to_js(_shell, cstr, (uint32_t)strlen(cstr));
    }
}

- (void)sendRaw:(NSString*)jsonString {
    if (!_wsTask || !_connected) return;
    NSURLSessionWebSocketMessage* wsMsg = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];
    [_wsTask sendMessage:wsMsg completionHandler:^(NSError* error) {
        if (error) NSLog(@"[Guava/Engine] Send error: %@", error.localizedDescription);
    }];
}

// ── NSURLSessionWebSocketDelegate ────────────────────────────────────────

- (void)URLSession:(NSURLSession*)session
    webSocketTask:(NSURLSessionWebSocketTask*)webSocketTask
    didOpenWithProtocol:(NSString*)protocol {
    NSLog(@"[Guava/Engine] Connected to %@", kEngineURL);
    _connected = YES;
    // Notify JS that engine is connected.
    const char* msg = "{\"type\":\"engine.connected\"}";
    citron_send_to_js(_shell, msg, (uint32_t)strlen(msg));
}

- (void)URLSession:(NSURLSession*)session
    webSocketTask:(NSURLSessionWebSocketTask*)webSocketTask
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
              reason:(NSData*)reason {
    NSLog(@"[Guava/Engine] Disconnected (code=%ld)", (long)closeCode);
    _connected = NO;
    // Notify JS of disconnection.
    const char* msg = "{\"type\":\"engine.disconnected\",\"info\":{\"code\":null,\"restarting\":true}}";
    citron_send_to_js(_shell, msg, (uint32_t)strlen(msg));
    [self scheduleReconnect];
}

@end

// ── Application State ────────────────────────────────────────────────────

static CitronShell* g_shell = nullptr;
static EngineRPC*   g_engine = nil;

// Callback: messages from JS → native (via citron.postMessage).
// The preload bridge sends JSON-RPC messages: { jsonrpc: "2.0", id, method, params }
// And fire-and-forget viewport messages: { jsonrpc: "2.0", method, params }
static void onJSMessage(const char* json, uint32_t len, void* /*userdata*/) {
    NSData* data = [NSData dataWithBytes:json length:len];
    NSDictionary* msg = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!msg) {
        fprintf(stderr, "[Guava] Invalid JSON from JS: %.*s\n", (int)len, json);
        return;
    }

    NSString* method = msg[@"method"];
    NSDictionary* params = msg[@"params"] ?: @{};
    NSNumber* msgId = msg[@"id"];  // may be nil for fire-and-forget

    // ── Local handling for viewport commands that affect Citron natively ──

    if ([method isEqualToString:@"viewport.attachSurface"]) {
        // Citron handles IOSurface natively — update viewport rect.
        NSNumber* surfaceId = params[@"surfaceId"];
        if (surfaceId) {
            citron_set_scene_surface(g_shell, [surfaceId unsignedIntValue]);
        }
        int32_t x = [params[@"x"] intValue];
        int32_t y = [params[@"y"] intValue];
        int32_t w = [params[@"w"] intValue];
        int32_t h = [params[@"h"] intValue];
        if (w > 0 && h > 0) {
            citron_set_viewport_rect(g_shell, x, y, w, h);
        }
        return;
    }

    if ([method isEqualToString:@"viewport.updateBounds"]) {
        // Update Citron shell viewport rect for Metal composition.
        int32_t x = [params[@"x"] intValue];
        int32_t y = [params[@"y"] intValue];
        int32_t w = [params[@"w"] intValue];
        int32_t h = [params[@"h"] intValue];
        citron_set_viewport_rect(g_shell, x, y, w, h);
        // Also forward to engine so it knows the viewport bounds.
        if (g_engine.connected && msgId) {
            [g_engine sendRaw:[[NSString alloc] initWithBytes:json length:len encoding:NSUTF8StringEncoding]];
        }
        return;
    }

    if ([method isEqualToString:@"viewport.updateSurface"]) {
        // IOSurface update — re-lookup.
        NSNumber* surfaceId = params[@"surfaceId"];
        if (surfaceId) {
            citron_set_scene_surface(g_shell, [surfaceId unsignedIntValue]);
        }
        return;
    }

    if ([method isEqualToString:@"viewport.detach"]) {
        citron_set_scene_surface(g_shell, 0);
        return;
    }

    // ── viewport.setRect: update Citron + forward to engine ──

    if ([method isEqualToString:@"viewport.setRect"]) {
        int32_t x = [params[@"x"] intValue];
        int32_t y = [params[@"y"] intValue];
        int32_t w = [params[@"w"] intValue] ?: [params[@"width"] intValue];
        int32_t h = [params[@"h"] intValue] ?: [params[@"height"] intValue];
        citron_set_viewport_rect(g_shell, x, y, w, h);
        // Forward to engine.
        [g_engine sendRaw:[[NSString alloc] initWithBytes:json length:len encoding:NSUTF8StringEncoding]];
        return;
    }

    // ── Default: forward to engine as raw JSON-RPC ──

    if (method && g_engine) {
        [g_engine sendRaw:[[NSString alloc] initWithBytes:json length:len encoding:NSUTF8StringEncoding]];
    }
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

        g_shell = citron_create(&config);
        if (!g_shell) {
            fprintf(stderr, "[Guava] Failed to create shell\n");
            return 1;
        }

        // Register JS message handler.
        citron_on_message(g_shell, onJSMessage, nullptr);

        // Connect to Guava engine.
        g_engine = [[EngineRPC alloc] initWithShell:g_shell];
        [g_engine connect];

        // Main loop: process events + CEF + render.
        while (citron_tick(g_shell)) {
            usleep(16000);
        }

        [g_engine disconnect];
        citron_destroy(g_shell);
    }
    return 0;
}
