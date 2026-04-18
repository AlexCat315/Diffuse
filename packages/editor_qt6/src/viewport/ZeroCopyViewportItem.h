#pragma once

#include <QQuickItem>
#include <qqmlintegration.h>

class QRhiTexture;
class QSGTexture;
class QSGNode;

class ZeroCopyViewportItem : public QQuickItem
{
    Q_OBJECT
    QML_NAMED_ELEMENT(ZeroCopyViewport)
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)

public:
    explicit ZeroCopyViewportItem(QQuickItem *parent = nullptr);
    ~ZeroCopyViewportItem() override;

    bool active() const { return m_active; }

    Q_INVOKABLE void setSurfaceHandle(qint64 surfaceId, int width, int height);

signals:
    void activeChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *updatePaintNodeData) override;
    void releaseResources() override;
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;

private:
    void clearTextureResources();
    bool ensureTextureReady();
    void updateActiveState(bool next);

    bool m_active {false};
    qint64 m_surfaceId {0};
    int m_surfaceWidth {0};
    int m_surfaceHeight {0};
    bool m_textureDirty {true};
    void *m_nativeMetalTexture {nullptr};
    QRhiTexture *m_rhiTexture {nullptr};
    QSGTexture *m_sgTexture {nullptr};
};
