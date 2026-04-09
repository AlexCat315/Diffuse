// Citron — WKWebView bridge for React UI.
// Provides JS ↔ Native communication via WKScriptMessageHandler.
//
// JS API (injected into page):
//   window.citron.postMessage({method, id?, params})  → sends to native
//   window.citron.onNativeMessage = (msg) => { ... }  → receives from native
//   window.citron.platform = "macos"
//   window.citron.isNative = true
#import "Citron.h"

@interface WebViewBridge ()
@property (nonatomic, copy) WebViewMessageHandler messageHandler;
@end

@implementation WebViewBridge

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super init];
    if (!self) return nil;

    WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];

    // Allow SharedArrayBuffer (requires cross-origin isolation headers in
    // production, but for local files WKWebView enables it by default).
    config.defaultWebpagePreferences.allowsContentJavaScript = YES;

    // Inject the citron bridge script before any page scripts run.
    NSString* bridgeScript = @
        "window.citron = {"
        "  isNative: true,"
        "  platform: 'macos',"
        "  _callbacks: {},"
        "  _nextId: 1,"
        "  postMessage: function(msg) {"
        "    window.webkit.messageHandlers.citron.postMessage(msg);"
        "  },"
        "  invoke: function(method, params) {"
        "    return new Promise(function(resolve, reject) {"
        "      var id = window.citron._nextId++;"
        "      window.citron._callbacks[id] = { resolve: resolve, reject: reject };"
        "      window.citron.postMessage({ method: method, id: id, params: params || {} });"
        "      setTimeout(function() {"
        "        if (window.citron._callbacks[id]) {"
        "          delete window.citron._callbacks[id];"
        "          reject(new Error('Citron RPC timeout: ' + method));"
        "        }"
        "      }, 30000);"
        "    });"
        "  },"
        "  onNativeMessage: null,"
        "  _handleNative: function(msg) {"
        "    if (msg.id && window.citron._callbacks[msg.id]) {"
        "      var cb = window.citron._callbacks[msg.id];"
        "      delete window.citron._callbacks[msg.id];"
        "      if (msg.error) { cb.reject(new Error(msg.error.message || 'Unknown error')); }"
        "      else { cb.resolve(msg.result); }"
        "    } else if (window.citron.onNativeMessage) {"
        "      window.citron.onNativeMessage(msg);"
        "    }"
        "  }"
        "};";

    WKUserScript* script = [[WKUserScript alloc]
        initWithSource:bridgeScript
         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
      forMainFrameOnly:YES];
    [config.userContentController addUserScript:script];

    // Register the message handler.
    [config.userContentController addScriptMessageHandler:self name:@"citron"];

    // Enable Safari Web Inspector for debugging (development).
#ifdef DEBUG
    [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
#endif

    _webView = [[WKWebView alloc] initWithFrame:frame configuration:config];
    _webView.navigationDelegate = self;
    _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Make WKWebView background transparent so it blends with the dark theme.
    [_webView setValue:@NO forKey:@"drawsBackground"];

    return self;
}

- (void)loadURL:(NSURL*)url {
    if ([url isFileURL]) {
        NSString* dir = [[url URLByDeletingLastPathComponent] path];
        [_webView loadFileURL:url
      allowingReadAccessToURL:[NSURL fileURLWithPath:dir isDirectory:YES]];
    } else {
        [_webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
}

- (void)evaluateJS:(NSString*)script completion:(void(^ _Nullable)(id _Nullable, NSError* _Nullable))completion {
    [_webView evaluateJavaScript:script completionHandler:completion];
}

- (void)setMessageHandler:(WebViewMessageHandler)handler {
    _messageHandler = handler;
}

- (void)sendToJS:(NSDictionary*)message {
    NSError* error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
    if (error) {
        NSLog(@"[Citron/WebBridge] JSON serialization error: %@", error);
        return;
    }
    NSString* json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString* script = [NSString stringWithFormat:@"window.citron._handleNative(%@)", json];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_webView evaluateJavaScript:script completionHandler:nil];
    });
}

// ── WKScriptMessageHandler ───────────────────────────────────────────────

- (void)userContentController:(WKUserContentController*)controller
      didReceiveScriptMessage:(WKScriptMessage*)message {
    if (![message.name isEqualToString:@"citron"]) return;

    if (![message.body isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[Citron/WebBridge] Invalid message body (expected object): %@", message.body);
        return;
    }

    NSDictionary* body = (NSDictionary*)message.body;
    if (_messageHandler) {
        _messageHandler(body);
    }
}

// ── WKNavigationDelegate ─────────────────────────────────────────────────

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation {
    NSLog(@"[Citron/WebBridge] Page loaded: %@", webView.URL);
}

- (void)webView:(WKWebView*)webView didFailNavigation:(WKNavigation*)navigation
      withError:(NSError*)error {
    NSLog(@"[Citron/WebBridge] Navigation failed: %@", error);
}

- (void)webView:(WKWebView*)webView
    decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction
                    decisionHandler:(void(^)(WKNavigationActionPolicy))decisionHandler {
    // Allow all navigations (local file and localhost dev server).
    decisionHandler(WKNavigationActionPolicyAllow);
}

@end
