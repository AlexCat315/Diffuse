#pragma once

#include <QQuickItem>
#include <QBasicTimer>
#include <cstdint>

class EngineClient;

// Forward declaration for Objective-C types
#ifdef __OBJC__
@class CAMetalLayer;
#else
class CAMetalLayer;
#endif

/**
 * MetalViewportItem — QML-compatible Metal viewport renderer
 *
 * Renders engine's IOSurface using Metal CAMetalLayer directly.
 * - Integrates with Qt Quick scene graph
 * - Handles 60 FPS rendering loop via timer
 * - Routes mouse/keyboard events to engine
 * - Platform: macOS only
 */

class MetalViewportItem : public QQuickItem
{
    Q_OBJECT

public:
    explicit MetalViewportItem(QQuickItem* parent = nullptr);
    ~MetalViewportItem() override;

    // QML property: engine client reference
    Q_PROPERTY(EngineClient* engine READ engine WRITE setEngine NOTIFY engineChanged)
    
    EngineClient* engine() const { return engine_; }
    void setEngine(EngineClient* engine);

public slots:
    void attachToEngine();
    void detachFromEngine();

signals:
    void engineChanged();
    void viewportReady();
    void entityPicked(int entityId);

protected:
    void geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) override;
    void itemChange(ItemChange change, const ItemChangeData& value) override;
    
    void wheelEvent(QWheelEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void keyPressEvent(QKeyEvent* event) override;
    void keyReleaseEvent(QKeyEvent* event) override;

    void timerEvent(QTimerEvent* event) override;

private:
    void syncViewportSize();
    void initializeMetalLayer();
    void renderFrame();
    void beginIOSurfaceMode();
    
    void sendMouseInput(const QString& type, QMouseEvent* event,
                        const QString& button = {}, int clicks = 0);
    void sendKeyInput(const QString& type, QKeyEvent* event);

    EngineClient* engine_ = nullptr;
    bool attached_ = false;
    bool engineConnected_ = false;
    bool useIOSurface_ = false;
    uint64_t currentIOSurfaceId_ = 0;
    
    // 60 FPS render timer
    QBasicTimer renderTimer_;
    
    // Metal rendering (Objective-C++)
    void* metalDevice_;                 // id<MTLDevice>
    void* metalCommandQueue_;           // id<MTLCommandQueue>
    void* metalLayer_;                  // CAMetalLayer*
    void* metalRenderPipelineState_;    // id<MTLRenderPipelineState>
    void* lastIOSurfaceTexture_;        // id<MTLTexture>
    void* nativeWindowHandle_;          // NSView* or similar
    uint32_t frameCounter_ = 0;
};
