#pragma once

#include <QWidget>
#include <QJsonValue>

class EngineClient;

// Forward declarationfor Objective-C types
#ifdef __OBJC__
@class CAMetalLayer;
#else
class CAMetalLayer;
#endif

/// ViewportWidget — Renders engine's IOSurface using Metal CAMetalLayer.
///
/// macOS-specific implementation using direct Metal rendering.
/// - Engine renders to IOSurface (headless mode)
/// - CAMetalLayer blits IOSurface to screen each frame
/// - Handles mouse/keyboard input routing
class ViewportWidget : public QWidget
{
    Q_OBJECT

public:
    explicit ViewportWidget(EngineClient* engine, QWidget* parent = nullptr);
    ~ViewportWidget() override;

    void attachToEngine();
    void detachFromEngine();

signals:
    void viewportReady();
    void entityPicked(int entityId);

protected:
    void resizeEvent(QResizeEvent* event) override;
    void showEvent(QShowEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void wheelEvent(QWheelEvent* event) override;
    void keyPressEvent(QKeyEvent* event) override;
    void keyReleaseEvent(QKeyEvent* event) override;
    void enterEvent(QEnterEvent* event) override;
    void leaveEvent(QEvent* event) override;
    void focusInEvent(QFocusEvent* event) override;
    void paintEvent(QPaintEvent* event) override;

private:
    void sendMouseInput(const QString& type, QMouseEvent* event,
                        const QString& button = {}, int clicks = 0);
    void sendKeyInput(const QString& type, QKeyEvent* event);
    void syncViewportSize();
    void initializeMetalLayer();
    void renderFrame();                    // Metal render loop
    void beginIOSurfaceMode();

    EngineClient* engine_;
    bool attached_ = false;
    bool engineConnected_ = false;
    bool useIOSurface_ = false;
    uint64_t currentIOSurfaceId_ = 0;

    // Metal rendering (Objective-C++)
    void* metalDevice_;                    // id<MTLDevice> (opaque)
    void* metalCommandQueue_;              // id<MTLCommandQueue>
    void* metalLayer_;                     // CAMetalLayer* (opaque)
    void* metalRenderPipelineState_;       // id<MTLRenderPipelineState>
    void* lastIOSurfaceTexture_;           // id<MTLTexture> (opaque)
    uint32_t frameCounter_ = 0;            // For animating viewport
};
