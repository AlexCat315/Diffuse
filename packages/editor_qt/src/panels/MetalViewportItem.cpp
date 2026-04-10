#include "MetalViewportItem.h"
#include "engine/EngineClient.h"
#include <QMouseEvent>
#include <QKeyEvent>
#include <QWheelEvent>
#include <QJsonObject>
#include <QDebug>

MetalViewportItem::MetalViewportItem(QQuickItem* parent)
    : QQuickItem(parent),
      metalDevice_(nullptr),
      metalCommandQueue_(nullptr),
      metalLayer_(nullptr),
      metalRenderPipelineState_(nullptr),
      lastIOSurfaceTexture_(nullptr),
      nativeWindowHandle_(nullptr)
{
    setAcceptedMouseButtons(Qt::AllButtons);
    setAcceptHoverEvents(true);
    setFocus(true);
    
    // Initialize Metal layer on first visibility
    connect(this, &QQuickItem::visibleChanged, this, [this]() {
        if (isVisible() && !metalLayer_) {
            initializeMetalLayer();
        }
    });
}

MetalViewportItem::~MetalViewportItem()
{
    detachFromEngine();
    
    // Cleanup Metal resources
    // TODO: proper Metal cleanup (release textures, command queue, device)
}

void MetalViewportItem::setEngine(EngineClient* engine)
{
    if (engine_ == engine) return;
    
    if (engine_) {
        detachFromEngine();
    }
    
    engine_ = engine;
    emit engineChanged();
    
    if (engine_) {
        attachToEngine();
    }
}

void MetalViewportItem::attachToEngine()
{
    if (!engine_ || attached_) return;
    
    attached_ = true;
    
    // Request IOSurface mode from engine
    engine_->call("viewport.setIOSurfaceMode", {{"enabled", true}});
    
    // Start 60 FPS render loop
    renderTimer_.start(16, this);  // ~60 FPS
    
    emit viewportReady();
}

void MetalViewportItem::detachFromEngine()
{
    if (!engine_ || !attached_) return;
    
    renderTimer_.stop();
    
    if (engine_) {
        engine_->call("viewport.setIOSurfaceMode", {{"enabled", false}});
    }
    
    attached_ = false;
}

void MetalViewportItem::geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry)
{
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    
    if (newGeometry.size() != oldGeometry.size()) {
        syncViewportSize();
    }
}

void MetalViewportItem::itemChange(ItemChange change, const ItemChangeData& value)
{
    QQuickItem::itemChange(change, value);
    
    if (change == ItemVisibleHasChanged && value.boolValue) {
        if (!metalLayer_) {
            initializeMetalLayer();
        }
    }
}

void MetalViewportItem::syncViewportSize()
{
    if (!engine_) return;
    
    int w = static_cast<int>(QQuickItem::width());
    int h = static_cast<int>(QQuickItem::height());
    
    if (w > 0 && h > 0) {
        engine_->call("viewport.resize", {
            {"width", w},
            {"height", h}
        });
    }
}

void MetalViewportItem::initializeMetalLayer()
{
    // TODO: Implement Metal layer initialization
    // This requires Objective-C++ code to:
    // 1. Create CAMetalLayer
    // 2. Attach to QQuickItem's native window
    // 3. Create MTLDevice and MTLCommandQueue
    // For now, log initialization
    
    qDebug() << "Metal viewport initialized: " << width() << "x" << height();
}

void MetalViewportItem::renderFrame()
{
    if (!engine_ || !metalLayer_) return;
    
    // TODO: Implement Metal rendering loop
    // This should:
    // 1. Query current IOSurface from engine
    // 2. Create MTLTexture from IOSurface
    // 3. Present to Metal layer
    
    frameCounter_++;
}

void MetalViewportItem::beginIOSurfaceMode()
{
    if (!engine_) return;
    
    engine_->call("viewport.IOSurfaceModeStart", {}, [this](const QJsonValue& result, const QString& error) {
        if (!error.isEmpty()) {
            qWarning() << "IOSurface mode failed:" << error;
            return;
        }
        if (result.isObject()) {
            useIOSurface_ = true;
            currentIOSurfaceId_ = static_cast<uint64_t>(result["ioSurfaceId"].toDouble());
            qDebug() << "IOSurface mode started, ID:" << currentIOSurfaceId_;
        }
    });
}

void MetalViewportItem::timerEvent(QTimerEvent* event)
{
    if (event->timerId() == renderTimer_.timerId()) {
        renderFrame();
    }
    QQuickItem::timerEvent(event);
}

// ── Input Handling ──────────────────────────────────────────────────────

void MetalViewportItem::sendMouseInput(const QString& type, QMouseEvent* event,
                                       const QString& button, int clicks)
{
    if (!engine_) return;
    
    QJsonObject data{
        {"type", type},
        {"x", static_cast<int>(event->position().x())},
        {"y", static_cast<int>(event->position().y())},
        {"modifiers", static_cast<int>(event->modifiers())},
    };
    
    if (!button.isEmpty()) {
        data["button"] = button;
    }
    if (clicks > 0) {
        data["clicks"] = clicks;
    }
    
    engine_->call("viewport.onMouseEvent", data);
}

void MetalViewportItem::mousePressEvent(QMouseEvent* event)
{
    QString button = "left";
    if (event->button() == Qt::RightButton) button = "right";
    else if (event->button() == Qt::MiddleButton) button = "middle";
    
    sendMouseInput("press", event, button, 1);
    event->accept();
}

void MetalViewportItem::mouseReleaseEvent(QMouseEvent* event)
{
    QString button = "left";
    if (event->button() == Qt::RightButton) button = "right";
    else if (event->button() == Qt::MiddleButton) button = "middle";
    
    sendMouseInput("release", event, button);
    event->accept();
}

void MetalViewportItem::mouseMoveEvent(QMouseEvent* event)
{
    sendMouseInput("move", event);
    event->accept();
}

void MetalViewportItem::wheelEvent(QWheelEvent* event)
{
    if (!engine_) return;
    
    engine_->call("viewport.onScroll", {
        {"delta", event->angleDelta().y()},
        {"x", static_cast<int>(event->position().x())},
        {"y", static_cast<int>(event->position().y())}
    });
    
    event->accept();
}

void MetalViewportItem::sendKeyInput(const QString& type, QKeyEvent* event)
{
    if (!engine_) return;
    
    engine_->call("viewport.onKeyEvent", {
        {"type", type},
        {"key", event->key()},
        {"text", event->text()},
        {"modifiers", static_cast<int>(event->modifiers())}
    });
}

void MetalViewportItem::keyPressEvent(QKeyEvent* event)
{
    if (!event->isAutoRepeat()) {
        sendKeyInput("press", event);
    }
    event->accept();
}

void MetalViewportItem::keyReleaseEvent(QKeyEvent* event)
{
    if (!event->isAutoRepeat()) {
        sendKeyInput("release", event);
    }
    event->accept();
}
