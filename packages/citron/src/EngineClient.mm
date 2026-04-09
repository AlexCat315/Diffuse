// Citron — Engine WebSocket JSON-RPC 2.0 client.
// Connects to ws://127.0.0.1:9100 and provides call/subscribe API.
#import "Citron.h"

static NSString* const kEngineURL = @"ws://127.0.0.1:9100";
static const NSTimeInterval kReconnectInterval = 2.0;
static const NSTimeInterval kRPCTimeout = 30.0;

@interface EngineClient () {
    NSURLSessionWebSocketTask* _wsTask;
    NSURLSession*              _session;
    NSInteger                  _nextId;
    NSMutableDictionary<NSNumber*, void(^)(NSDictionary*, NSError*)>* _pendingCalls;
    NSMutableDictionary<NSString*, NSMutableArray<void(^)(NSDictionary*)>*>* _notificationHandlers;
    BOOL                       _shouldReconnect;
}
@end

@implementation EngineClient

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _nextId = 1;
    _pendingCalls = [NSMutableDictionary new];
    _notificationHandlers = [NSMutableDictionary new];
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

    NSLog(@"[Citron/Engine] Connecting to %@...", kEngineURL);
}

- (void)disconnect {
    _shouldReconnect = NO;
    _connected = NO;
    [_wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    _wsTask = nil;

    // Fail all pending calls.
    NSError* err = [NSError errorWithDomain:@"Citron" code:-1
                                   userInfo:@{NSLocalizedDescriptionKey: @"Disconnected"}];
    for (NSNumber* key in _pendingCalls.allKeys) {
        void(^cb)(NSDictionary*, NSError*) = _pendingCalls[key];
        cb(nil, err);
    }
    [_pendingCalls removeAllObjects];
}

- (void)scheduleReconnect {
    if (!_shouldReconnect) return;
    _wsTask = nil;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReconnectInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self->_shouldReconnect && !self->_wsTask) {
            [self doConnect];
        }
    });
}

// ── Send / Receive ───────────────────────────────────────────────────────

- (void)listenForMessages {
    __weak EngineClient* weakSelf = self;

    [_wsTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage* msg, NSError* error) {
        EngineClient* self = weakSelf;
        if (!self) return;

        if (error) {
            NSLog(@"[Citron/Engine] WebSocket receive error: %@", error);
            self->_connected = NO;
            [self scheduleReconnect];
            return;
        }

        if (msg.type == NSURLSessionWebSocketMessageTypeString) {
            [self handleMessage:msg.string];
        }

        // Continue listening.
        [self listenForMessages];
    }];
}

- (void)handleMessage:(NSString*)jsonString {
    NSData* data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSError* parseError = nil;
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
    if (parseError || ![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[Citron/Engine] Invalid JSON: %@", parseError ?: jsonString);
        return;
    }

    // JSON-RPC response (has "id").
    NSNumber* msgId = json[@"id"];
    if (msgId && _pendingCalls[msgId]) {
        void(^cb)(NSDictionary*, NSError*) = _pendingCalls[msgId];
        [_pendingCalls removeObjectForKey:msgId];

        if (json[@"error"]) {
            NSDictionary* errObj = json[@"error"];
            NSString* errMsg = errObj[@"message"] ?: @"Unknown engine error";
            cb(nil, [NSError errorWithDomain:@"EngineRPC" code:-1
                                    userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
        } else {
            cb(json[@"result"], nil);
        }
        return;
    }

    // JSON-RPC notification (has "method" but no "id").
    NSString* method = json[@"method"];
    if (method) {
        NSDictionary* params = json[@"params"] ?: @{};

        // Dispatch to specific handlers.
        NSArray<void(^)(NSDictionary*)>* handlers = _notificationHandlers[method];
        for (void(^handler)(NSDictionary*) in handlers) {
            handler(params);
        }

        // Also dispatch to wildcard handlers.
        NSArray<void(^)(NSDictionary*)>* wildcards = _notificationHandlers[@"*"];
        for (void(^handler)(NSDictionary*) in wildcards) {
            handler(@{@"method": method, @"params": params});
        }
    }
}

- (void)call:(NSString*)method
      params:(NSDictionary* _Nullable)params
  completion:(void(^)(NSDictionary* _Nullable, NSError* _Nullable))completion {

    if (!_wsTask || !_connected) {
        NSError* err = [NSError errorWithDomain:@"Citron" code:-1
                                       userInfo:@{NSLocalizedDescriptionKey: @"Not connected to engine"}];
        completion(nil, err);
        return;
    }

    NSNumber* callId = @(_nextId++);

    NSDictionary* rpcMsg = @{
        @"jsonrpc": @"2.0",
        @"id": callId,
        @"method": method,
        @"params": params ?: @{}
    };

    NSError* serializeError = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:rpcMsg options:0 error:&serializeError];
    if (serializeError) {
        completion(nil, serializeError);
        return;
    }

    _pendingCalls[callId] = completion;

    // Timeout.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRPCTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        void(^cb)(NSDictionary*, NSError*) = self->_pendingCalls[callId];
        if (cb) {
            [self->_pendingCalls removeObjectForKey:callId];
            cb(nil, [NSError errorWithDomain:@"Citron" code:-2
                                    userInfo:@{NSLocalizedDescriptionKey: @"RPC timeout"}]);
        }
    });

    NSString* jsonString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage* wsMsg =
        [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];
    [_wsTask sendMessage:wsMsg completionHandler:^(NSError* error) {
        if (error) {
            NSLog(@"[Citron/Engine] Send error: %@", error);
        }
    }];
}

- (void)onNotification:(NSString*)method handler:(void(^)(NSDictionary*))handler {
    if (!_notificationHandlers[method]) {
        _notificationHandlers[method] = [NSMutableArray new];
    }
    [_notificationHandlers[method] addObject:handler];
}

// ── NSURLSessionWebSocketDelegate ────────────────────────────────────────

- (void)URLSession:(NSURLSession*)session
    webSocketTask:(NSURLSessionWebSocketTask*)webSocketTask
    didOpenWithProtocol:(NSString*)protocol {
    NSLog(@"[Citron/Engine] Connected to %@", kEngineURL);
    _connected = YES;
}

- (void)URLSession:(NSURLSession*)session
    webSocketTask:(NSURLSessionWebSocketTask*)webSocketTask
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
              reason:(NSData*)reason {
    NSLog(@"[Citron/Engine] Disconnected (code=%ld)", (long)closeCode);
    _connected = NO;
    [self scheduleReconnect];
}

@end
