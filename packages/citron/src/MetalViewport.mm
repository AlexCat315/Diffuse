// Citron — MetalViewport: displays engine IOSurface at VSync via CVDisplayLink.
// Zero-copy: the engine writes to an IOSurface via Metal, and we display it
// directly as a CALayer's contents — no pixel copies, no GPU uploads.
#import "Citron.h"
#import <QuartzCore/CATransaction.h>

@interface MetalViewport () {
    IOSurfaceRef       _surface;
    CALayer*           _contentLayer;
    CVDisplayLinkRef   _displayLink;
    uint32_t           _lastSeed;
}
- (void)pollSurface;
@end

// CVDisplayLink callback — runs on a high-priority thread at VSync.
static CVReturn ViewportDisplayLinkCallback(
    CVDisplayLinkRef       displayLink,
    const CVTimeStamp*     inNow,
    const CVTimeStamp*     inOutputTime,
    CVOptionFlags          flagsIn,
    CVOptionFlags*         flagsOut,
    void*                  ctx)
{
    MetalViewport* viewport = (__bridge MetalViewport*)ctx;
    [viewport pollSurface];
    return kCVReturnSuccess;
}

@implementation MetalViewport

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor blackColor].CGColor;

    // Content layer that will hold the IOSurface.
    _contentLayer = [CALayer layer];
    _contentLayer.frame = self.bounds;
    _contentLayer.contentsGravity = kCAGravityResize;
    _contentLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    _contentLayer.actions = @{
        @"contents": [NSNull null],
        @"bounds":   [NSNull null],
        @"position": [NSNull null],
        @"frame":    [NSNull null],
    };
    [self.layer addSublayer:_contentLayer];

    _lastSeed = 0;
    _surface = NULL;
    _displayLink = NULL;

    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _contentLayer.frame = self.bounds;
    _contentLayer.contentsScale = self.window.backingScaleFactor;
    [CATransaction commit];
}

// Called from the CVDisplayLink thread at VSync.
- (void)pollSurface {
    if (!_surface) return;

    uint32_t seed = IOSurfaceGetSeed(_surface);
    if (seed == _lastSeed) return;
    _lastSeed = seed;

    // Assign the new frame on the main thread.
    IOSurfaceRef surface = _surface;
    CFRetain(surface);
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self->_contentLayer.contents = (__bridge id)surface;
        [CATransaction commit];
        CFRelease(surface);
    });
}

- (void)attachSurface:(uint32_t)surfaceId {
    [self detach];

    IOSurfaceRef surface = IOSurfaceLookup(surfaceId);
    if (!surface) {
        NSLog(@"[Citron/Viewport] IOSurfaceLookup(%u) failed", surfaceId);
        return;
    }

    _surface = surface;
    _lastSeed = 0;

    // Set initial contents.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _contentLayer.contents = (__bridge id)_surface;
    _contentLayer.contentsScale = self.window.backingScaleFactor;
    [CATransaction commit];

    // Start CVDisplayLink.
    CVReturn cvr = CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    if (cvr == kCVReturnSuccess) {
        CVDisplayLinkSetOutputCallback(_displayLink, ViewportDisplayLinkCallback, (__bridge void*)self);
        CVDisplayLinkStart(_displayLink);
    }

    _isAttached = YES;
    NSLog(@"[Citron/Viewport] Attached to IOSurface %u (%zux%zu)",
          surfaceId, IOSurfaceGetWidth(_surface), IOSurfaceGetHeight(_surface));
}

- (void)updateSurface:(uint32_t)surfaceId {
    IOSurfaceRef surface = IOSurfaceLookup(surfaceId);
    if (!surface) {
        NSLog(@"[Citron/Viewport] updateSurface: IOSurfaceLookup(%u) failed", surfaceId);
        return;
    }

    if (_surface) CFRelease(_surface);
    _surface = surface;
    _lastSeed = 0;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _contentLayer.contents = (__bridge id)_surface;
    [CATransaction commit];

    NSLog(@"[Citron/Viewport] Updated to IOSurface %u (%zux%zu)",
          surfaceId, IOSurfaceGetWidth(_surface), IOSurfaceGetHeight(_surface));
}

- (void)detach {
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
    if (_surface) {
        CFRelease(_surface);
        _surface = NULL;
    }
    _contentLayer.contents = nil;
    _isAttached = NO;
}

- (void)dealloc {
    [self detach];
    // ARC handles [super dealloc].
}

// ── Mouse event forwarding ──────────────────────────────────────────────
// These will be forwarded to the engine via RPC.

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)mouseDown:(NSEvent*)event      { [self forwardMouseEvent:event type:@"mouseDown"]; }
- (void)mouseUp:(NSEvent*)event        { [self forwardMouseEvent:event type:@"mouseUp"]; }
- (void)mouseDragged:(NSEvent*)event   { [self forwardMouseEvent:event type:@"mouseDragged"]; }
- (void)rightMouseDown:(NSEvent*)event { [self forwardMouseEvent:event type:@"rightMouseDown"]; }
- (void)rightMouseUp:(NSEvent*)event   { [self forwardMouseEvent:event type:@"rightMouseUp"]; }
- (void)rightMouseDragged:(NSEvent*)event { [self forwardMouseEvent:event type:@"rightMouseDragged"]; }
- (void)otherMouseDown:(NSEvent*)event { [self forwardMouseEvent:event type:@"otherMouseDown"]; }
- (void)otherMouseUp:(NSEvent*)event   { [self forwardMouseEvent:event type:@"otherMouseUp"]; }
- (void)otherMouseDragged:(NSEvent*)event { [self forwardMouseEvent:event type:@"otherMouseDragged"]; }
- (void)scrollWheel:(NSEvent*)event    { [self forwardMouseEvent:event type:@"scrollWheel"]; }
- (void)mouseMoved:(NSEvent*)event     { [self forwardMouseEvent:event type:@"mouseMoved"]; }

- (void)forwardMouseEvent:(NSEvent*)event type:(NSString*)type {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat dpr = self.window.backingScaleFactor;

    // Flip Y: AppKit is bottom-left origin, engine expects top-left.
    CGFloat flippedY = self.bounds.size.height - loc.y;

    // Notify the JS side which can then call engine RPC.
    // The EditorWindow will pick up viewport:mouseInput messages.
    NSDictionary* msg = @{
        @"type": @"viewportMouse",
        @"event": type,
        @"x": @(loc.x * dpr),
        @"y": @(flippedY * dpr),
        @"cssX": @(loc.x),
        @"cssY": @(flippedY),
        @"buttons": @(event.buttonNumber),
        @"deltaX": @(event.deltaX),
        @"deltaY": @(event.deltaY),
        @"modifiers": @(event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask),
    };

    // Find the EditorWindow to route through its webBridge.
    EditorWindow* editor = (EditorWindow*)self.window;
    if ([editor isKindOfClass:[EditorWindow class]]) {
        [editor.webBridge sendToJS:msg];
    }
}

- (void)keyDown:(NSEvent*)event    { [self forwardKeyEvent:event type:@"keyDown"]; }
- (void)keyUp:(NSEvent*)event      { [self forwardKeyEvent:event type:@"keyUp"]; }

- (void)forwardKeyEvent:(NSEvent*)event type:(NSString*)type {
    NSDictionary* msg = @{
        @"type": @"viewportKey",
        @"event": type,
        @"keyCode": @(event.keyCode),
        @"characters": event.characters ?: @"",
        @"modifiers": @(event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask),
    };

    EditorWindow* editor = (EditorWindow*)self.window;
    if ([editor isKindOfClass:[EditorWindow class]]) {
        [editor.webBridge sendToJS:msg];
    }
}

@end
