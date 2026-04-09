#include "ViewportWidget.h"
#include "engine/EngineClient.h"
#include "util/MacOS.h"

#include <QMouseEvent>
#include <QKeyEvent>
#include <QWheelEvent>
#include <QJsonObject>
#include <QDebug>
#include <QTimer>

ViewportWidget::ViewportWidget(EngineClient* engine, QWidget* parent)
    : QWidget(parent)
    , engine_(engine)
{
    setFocusPolicy(Qt::StrongFocus);
    setMouseTracking(true);
    setAttribute(Qt::WA_NativeWindow, true);  // Ensure a real NSView is created
    setAttribute(Qt::WA_OpaquePaintEvent, true);
    setMinimumSize(320, 240);

    // Style: dark background while waiting for engine
    setStyleSheet("background-color: #1a1a2e;");

    // Auto-attach when engine connects AND widget is shown
    connect(engine_, &EngineClient::connected, this, [this]() {
        engineConnected_ = true;
        qDebug() << "[Viewport] Engine connected, widget shown:" << isVisible();
        // Wait for widget to be shown before attaching
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
        qDebug() << "[Viewport] Engine already connected";
    }
}

ViewportWidget::~ViewportWidget()
{
    detachFromEngine();
}

void ViewportWidget::attachToEngine()
{
    if (attached_ || !engineConnected_) return;

    // Ensure widget has a native window
    if (!isVisible() || !internalWinId()) {
        qDebug() << "[Viewport] Widget not yet visible or no native window, retrying...";
        QTimer::singleShot(500, this, &ViewportWidget::attachToEngine);
        return;
    }

    // Step 1: Set viewport size (in physical pixels)
    syncViewportSize();

    // Step 2: Try to attach engine window
    WId qtHandle = winId();
    uint64_t nativeHandle = getQtWidgetNSView(qtHandle);
    
    if (nativeHandle == 0) {
        qWarning() << "[Viewport] Failed to get native NSView, using IOSurface fallback";
        useIOSurface_ = true;
        return;
    }
    
    qDebug() << "[Viewport] Attaching engine to NSView:" << (void*)nativeHandle << "visible:" << isVisible() << "size:" << size();

    engine_->call("viewport.attachToParent",
        {{"parentHandle", (qint64)nativeHandle}},
        [this, nativeHandle](const QJsonValue& result, const QString& error) {
            if (!error.isEmpty()) {
                qWarning() << "[Viewport] attachToParent failed with handle" << (void*)nativeHandle << ":" << error;
                // Fallback: use IOSurface rendering (headless viewport)
                qDebug() << "[Viewport] Native attachment failed, using IOSurface fallback...";
                useIOSurface_ = true;
                // Schedule polling for IOSurface updates
                QTimer::singleShot(100, this, [this]() {
                    beginIOSurfaceMode();
                });
                return;
            }
            attached_ = true;
            qDebug() << "[Viewport] Engine attached successfully";
            emit viewportReady();
        });
}

void ViewportWidget::beginIOSurfaceMode()
{
    // Request initial viewport metrics and setup for IOSurface rendering
    engine_->call("viewport.getSurfaceId", {}, [this](const QJsonValue& result, const QString& error) {
        if (!error.isEmpty()) {
            qWarning() << "[Viewport] Failed to get IOSurface ID:" << error;
            return;
        }
        
        uint64_t surfaceId = result.toObject().value("surfaceId").toVariant().toULongLong();
        qDebug() << "[Viewport] Got IOSurface ID:" << surfaceId << "— rendering will be available once Metal layer is implemented";
        
        // TODO: Create CAMetalLayer, attach IOSurface to it, display
        // For now, just mark as ready with placeholder
        attached_ = true;
        emit viewportReady();
    });
}

void ViewportWidget::detachFromEngine()
{
    if (!attached_ || !engineConnected_) return;

    engine_->call("viewport.detachFromParent", {});
    attached_ = false;
}

// ── Resize ───────────────────────────────────────────────────────────────

void ViewportWidget::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    qDebug() << "[Viewport] Widget shown, attempting engine attach...";
    
    // Try to attach now that widget is visible
    if (engineConnected_ && !attached_) {
        QTimer::singleShot(100, this, &ViewportWidget::attachToEngine);
    }
}

void ViewportWidget::resizeEvent(QResizeEvent* event)
{
    QWidget::resizeEvent(event);
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

    // Map Qt key names to engine format
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
