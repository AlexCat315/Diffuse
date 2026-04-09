#include "ViewportWidget.h"
#include "engine/EngineClient.h"

#include <QMouseEvent>
#include <QKeyEvent>
#include <QWheelEvent>
#include <QJsonObject>
#include <QJsonArray>
#include <QDebug>
#include <QTimer>
#include <QPainter>
#include <QPolygon>

// Objective-C headers
#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

// Helper: Create MTLTextureDescriptor from IOSurface
static MTLTextureDescriptor* createTextureDescriptorForIOSurface(IOSurfaceRef surface) {
    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    
    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:width
                                                                                 height:height
                                                                              mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return desc;
}

ViewportWidget::ViewportWidget(EngineClient* engine, QWidget* parent)
    : QWidget(parent)
    , engine_(engine)
    , metalDevice_(nil)
    , metalCommandQueue_(nil)
    , metalLayer_(nil)
    , metalRenderPipelineState_(nil)
    , lastIOSurfaceTexture_(nil)
{
    setFocusPolicy(Qt::StrongFocus);
    setMouseTracking(true);
    setAttribute(Qt::WA_NativeWindow, true);
    setAttribute(Qt::WA_OpaquePaintEvent, true);
    setMinimumSize(320, 240);

    setStyleSheet("background-color: #1a1a2e;");

    connect(engine_, &EngineClient::connected, this, [this]() {
        engineConnected_ = true;
        qDebug() << "[Viewport] Engine connected, widget shown:" << isVisible();
        if (isVisible()) {
            QTimer::singleShot(1000, this, &ViewportWidget::attachToEngine);
        }
    });

    connect(engine_, &EngineClient::disconnected, this, [this]() {
        engineConnected_ = false;
        attached_ = false;
        qDebug() << "[Viewport] Engine disconnected";
    });

    if (engine_->isConnected()) {
        engineConnected_ = true;
    }
}

ViewportWidget::~ViewportWidget()
{
    detachFromEngine();
    
    @autoreleasepool {
        // Release Metal resources safely
        if (metalLayer_) {
            CAMetalLayer* layer = (CAMetalLayer*)metalLayer_;
            [layer removeFromSuperlayer];
            metalLayer_ = nil;
        }
        
        if (metalRenderPipelineState_) {
            [(id)metalRenderPipelineState_ release];
            metalRenderPipelineState_ = nil;
        }
        
        if (metalCommandQueue_) {
            [(id)metalCommandQueue_ release];
            metalCommandQueue_ = nil;
        }
        
        if (metalDevice_) {
            [(id)metalDevice_ release];
            metalDevice_ = nil;
        }
    }
}

// ── Attachment ───────────────────────────────────────────────────────────

void ViewportWidget::attachToEngine()
{
    if (attached_ || !engineConnected_) return;

    if (!isVisible() || !internalWinId()) {
        qDebug() << "[Viewport] Widget not yet visible or no native window, retrying...";
        QTimer::singleShot(500, this, &ViewportWidget::attachToEngine);
        return;
    }

    syncViewportSize();
    
    // Always use IOSurface mode with Metal
    qDebug() << "[Viewport] Setting up Metal IOSurface rendering...";
    initializeMetalLayer();
    beginIOSurfaceMode();
}

void ViewportWidget::detachFromEngine()
{
    if (!attached_ || !engineConnected_) return;
    engine_->call("viewport.detachFromParent", {});
    attached_ = false;
}

// ── Metal Setup ──────────────────────────────────────────────────────────

void ViewportWidget::initializeMetalLayer()
{
    // Must be called from main thread
    @autoreleasepool {
        NSView* qtView = (NSView*)winId();
        if (!qtView) {
            qWarning() << "[Viewport] Failed to get native Qt NSView";
            return;
        }

        // Create Metal device
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            qWarning() << "[Viewport] Failed to create Metal device";
            return;
        }
        metalDevice_ = (void*)[device retain];
        
        // Create command queue
        id<MTLCommandQueue> commandQueue = [device newCommandQueue];
        if (!commandQueue) {
            qWarning() << "[Viewport] Failed to create Metal command queue";
            [device release];
            return;
        }
        metalCommandQueue_ = (void*)[commandQueue retain];

        // Create CAMetalLayer
        CAMetalLayer* metalLayer = [[CAMetalLayer alloc] init];
        if (!metalLayer) {
            qWarning() << "[Viewport] Failed to create CAMetalLayer";
            [commandQueue release];
            [device release];
            return;
        }
        
        metalLayer_ = (void*)metalLayer;

        // Configure layer
        [metalLayer setDevice:device];
        [metalLayer setOpaque:YES];
        [metalLayer setDrawableSize:CGSizeMake(width() * devicePixelRatio(), 
                                                height() * devicePixelRatio())];
        [metalLayer setPixelFormat:MTLPixelFormatBGRA8Unorm];
        [metalLayer setFramebufferOnly:NO];

        // Add layer to Qt view
        if (![qtView wantsLayer]) {
            [qtView setWantsLayer:YES];
        }
        
        CALayer* rootLayer = [qtView layer];
        if (rootLayer) {
            [rootLayer addSublayer:metalLayer];
            [metalLayer setFrame:[qtView bounds]];
        }

        qDebug() << "[Viewport] Metal device initialized, layer added to QWidget";
        
        // Release local reference (layer is retained by rootLayer)
        [commandQueue release];
        [device release];
    }
}

void ViewportWidget::beginIOSurfaceMode()
{
    if (!engineConnected_) return;

    engine_->call("viewport.getSurfaceId", {}, [this](const QJsonValue& result, const QString& error) {
        if (!error.isEmpty()) {
            qWarning() << "[Viewport] Failed to get IOSurface ID:" << error;
            return;
        }

        uint64_t surfaceId = result.toObject().value("surfaceId").toVariant().toULongLong();
        currentIOSurfaceId_ = surfaceId;
        
        qDebug() << "[Viewport] Got IOSurface ID:" << surfaceId << "— Metal rendering active";

        attached_ = true;
        useIOSurface_ = true;
        emit viewportReady();

        // Start render timer
        QTimer* renderTimer = new QTimer(this);
        renderTimer->setSingleShot(false);
        renderTimer->setInterval(16);  // ~60 FPS
        
        connect(renderTimer, &QTimer::timeout, this, &ViewportWidget::renderFrame);
        renderTimer->start();
    });
}

// ── Metal Rendering ─────────────────────────────────────────────────────

void ViewportWidget::renderFrame()
{
    if (!attached_ || currentIOSurfaceId_ == 0) return;

    frameCounter_++;

    @autoreleasepool {
        if (!metalDevice_ || !metalCommandQueue_ || !metalLayer_) {
            return;
        }

        CAMetalLayer* metalLayer = (CAMetalLayer*)metalLayer_;
        id<MTLDevice> device = (__bridge id<MTLDevice>)metalDevice_;
        id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)metalCommandQueue_;

        // Get drawable
        id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
        if (!drawable) {
            return;
        }

        @try {
            // Animated color cycle for visual feedback
            float hue = fmod(frameCounter_ / 120.0f, 1.0f);  // Cycle every 120 frames
            float r = fabs(sin(hue * 3.14159f * 2));
            float g = fabs(cos(hue * 3.14159f * 2 + 2.0f));
            float b = fabs(sin(hue * 3.14159f * 2 + 4.0f));

            // Create render pass
            MTLRenderPassDescriptor* renderPassDesc = [MTLRenderPassDescriptor renderPassDescriptor];
            renderPassDesc.colorAttachments[0].texture = drawable.texture;
            renderPassDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
            renderPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(r * 0.3, g * 0.3, b * 0.3, 1.0);
            renderPassDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

            // Create command buffer
            id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
            if (!commandBuffer) {
                return;
            }

            // Create render encoder
            id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDesc];
            if (!renderEncoder) {
                return;
            }

            [renderEncoder endEncoding];

            // Present
            [commandBuffer presentDrawable:drawable];
            [commandBuffer commit];

            // Log every 60 frames
            if ((frameCounter_ % 60) == 0) {
                qDebug() << "[Viewport] Rendering frame" << frameCounter_;
            }
        } @catch (NSException* e) {
            qWarning() << "[Viewport] Render exception:" << QString::fromNSString(e.description);
        }
    }
}

// ── Resize ───────────────────────────────────────────────────────────────

void ViewportWidget::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    qDebug() << "[Viewport] Widget shown, attempting engine attach...";
    
    if (engineConnected_ && !attached_) {
        QTimer::singleShot(100, this, &ViewportWidget::attachToEngine);
    }
}

void ViewportWidget::resizeEvent(QResizeEvent* event)
{
    QWidget::resizeEvent(event);
    
    if (metalLayer_) {
        CAMetalLayer* metalLayer = (CAMetalLayer*)metalLayer_;
        qreal dpr = devicePixelRatio();
        [metalLayer setDrawableSize:CGSizeMake(width() * dpr, height() * dpr)];
        [metalLayer setFrame:CGRectMake(0, 0, width(), height())];
    }

    if (attached_ && engineConnected_) {
        syncViewportSize();
    }
}

void ViewportWidget::syncViewportSize()
{
    if (!engineConnected_) return;

    qreal dpr = devicePixelRatio();
    int w = static_cast<int>(width() * dpr);
    int h = static_cast<int>(height() * dpr);

    engine_->call("viewport.setRect", {
        {"x", 0}, {"y", 0},
        {"width", w}, {"height", h}
    });
}

void ViewportWidget::paintEvent(QPaintEvent* event)
{
    // Custom paint disabled — Metal rendering handles display
    // but we still call base to prevent Qt warnings
    QWidget::paintEvent(event);
}

// ── Mouse Events ─────────────────────────────────────────────────────────

void ViewportWidget::mousePressEvent(QMouseEvent* event)
{
    setFocus();
    QString button = "left";
    if (event->button() == Qt::RightButton) button = "right";
    else if (event->button() == Qt::MiddleButton) button = "middle";
    sendMouseInput("mouseDown", event, button, 1);
}

void ViewportWidget::mouseReleaseEvent(QMouseEvent* event)
{
    QString button = "left";
    if (event->button() == Qt::RightButton) button = "right";
    else if (event->button() == Qt::MiddleButton) button = "middle";
    sendMouseInput("mouseUp", event, button, 1);
}

void ViewportWidget::mouseMoveEvent(QMouseEvent* event)
{
    sendMouseInput("mouseMove", event);
}

void ViewportWidget::wheelEvent(QWheelEvent* event)
{
    if (!engineConnected_) return;

    qreal dpr = devicePixelRatio();
    QPointF pos = event->position();

    engine_->call("viewport.sendInput", {
        {"type", "mouseWheel"},
        {"x", pos.x() * dpr},
        {"y", pos.y() * dpr},
        {"deltaX", event->angleDelta().x() / 120.0},
        {"deltaY", event->angleDelta().y() / 120.0},
        {"shift", bool(event->modifiers() & Qt::ShiftModifier)},
        {"ctrl", bool(event->modifiers() & Qt::ControlModifier)},
        {"alt", bool(event->modifiers() & Qt::AltModifier)}
    });
}

void ViewportWidget::enterEvent(QEnterEvent* event)
{
    QWidget::enterEvent(event);
    setCursor(Qt::CrossCursor);
}

void ViewportWidget::leaveEvent(QEvent* event)
{
    QWidget::leaveEvent(event);
    unsetCursor();
}

void ViewportWidget::focusInEvent(QFocusEvent* event)
{
    QWidget::focusInEvent(event);
}

void ViewportWidget::sendMouseInput(const QString& type, QMouseEvent* event,
                                     const QString& button, int clicks)
{
    if (!engineConnected_) return;

    qreal dpr = devicePixelRatio();
    QJsonObject params;
    params["type"] = type;
    params["x"] = event->pos().x() * dpr;
    params["y"] = event->pos().y() * dpr;
    if (!button.isEmpty()) params["button"] = button;
    if (clicks > 0) params["clicks"] = clicks;
    params["shift"] = bool(event->modifiers() & Qt::ShiftModifier);
    params["ctrl"] = bool(event->modifiers() & Qt::ControlModifier);
    params["alt"] = bool(event->modifiers() & Qt::AltModifier);

    engine_->call("viewport.sendInput", params);
}

// ── Key Events ───────────────────────────────────────────────────────────

void ViewportWidget::keyPressEvent(QKeyEvent* event)
{
    sendKeyInput("keyDown", event);
}

void ViewportWidget::keyReleaseEvent(QKeyEvent* event)
{
    sendKeyInput("keyUp", event);
}

void ViewportWidget::sendKeyInput(const QString& type, QKeyEvent* event)
{
    if (!engineConnected_) return;

    QString key;
    switch (event->key()) {
        case Qt::Key_W: key = "w"; break;
        case Qt::Key_A: key = "a"; break;
        case Qt::Key_S: key = "s"; break;
        case Qt::Key_D: key = "d"; break;
        case Qt::Key_Q: key = "q"; break;
        case Qt::Key_E: key = "e"; break;
        case Qt::Key_R: key = "r"; break;
        case Qt::Key_F: key = "f"; break;
        case Qt::Key_G: key = "g"; break;
        case Qt::Key_Delete: key = "Delete"; break;
        case Qt::Key_Backspace: key = "Backspace"; break;
        case Qt::Key_Escape: key = "Escape"; break;
        case Qt::Key_Space: key = "Space"; break;
        default:
            if (!event->text().isEmpty())
                key = event->text();
            else
                return;
    }

    engine_->call("viewport.sendInput", {
        {"type", type},
        {"key", key},
        {"shift", bool(event->modifiers() & Qt::ShiftModifier)},
        {"ctrl", bool(event->modifiers() & Qt::ControlModifier)},
        {"alt", bool(event->modifiers() & Qt::AltModifier)}
    });
}
