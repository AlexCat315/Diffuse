#include "ZeroCopyViewportItem.h"

#include "IosurfaceMetalBridge.h"

#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSGSimpleTextureNode>
#include <QSGTexture>

#include <rhi/qrhi.h>

ZeroCopyViewportItem::ZeroCopyViewportItem(QQuickItem *parent)
    : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
}

ZeroCopyViewportItem::~ZeroCopyViewportItem()
{
    clearTextureResources();
}

void ZeroCopyViewportItem::setSurfaceHandle(qint64 surfaceId, int width, int height)
{
    m_surfaceId = surfaceId;
    m_surfaceWidth = width;
    m_surfaceHeight = height;
    m_textureDirty = true;

    updateActiveState(m_surfaceId > 0 && m_surfaceWidth > 0 && m_surfaceHeight > 0);
    update();
}

void ZeroCopyViewportItem::geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry)
{
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    if (m_active)
    {
        update();
    }
}

QSGNode *ZeroCopyViewportItem::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *)
{
    if (!m_active)
    {
        delete oldNode;
        clearTextureResources();
        return nullptr;
    }

    if (!ensureTextureReady())
    {
        delete oldNode;
        return nullptr;
    }

    auto *node = static_cast<QSGSimpleTextureNode *>(oldNode);
    if (!node)
    {
        node = new QSGSimpleTextureNode();
        node->setOwnsTexture(false);
    }

    node->setRect(boundingRect());
    node->setTexture(m_sgTexture);
    node->markDirty(QSGNode::DirtyGeometry | QSGNode::DirtyMaterial);
    return node;
}

void ZeroCopyViewportItem::releaseResources()
{
    clearTextureResources();
    QQuickItem::releaseResources();
}

void ZeroCopyViewportItem::clearTextureResources()
{
    delete m_sgTexture;
    m_sgTexture = nullptr;

    delete m_rhiTexture;
    m_rhiTexture = nullptr;

    if (m_nativeMetalTexture)
    {
        guava_release_metal_texture(m_nativeMetalTexture);
        m_nativeMetalTexture = nullptr;
    }
}

bool ZeroCopyViewportItem::ensureTextureReady()
{
    if (!window())
    {
        return false;
    }

    if (!m_textureDirty && m_sgTexture)
    {
        return true;
    }

    clearTextureResources();

    auto *ri = window()->rendererInterface();
    if (!ri || ri->graphicsApi() != QSGRendererInterface::Metal)
    {
        return false;
    }

    auto *rhi = static_cast<QRhi *>(ri->getResource(window(), QSGRendererInterface::RhiResource));
    void *device = ri->getResource(window(), QSGRendererInterface::DeviceResource);
    if (!rhi || !device)
    {
        return false;
    }

    m_nativeMetalTexture = guava_create_metal_texture_from_iosurface(
        device,
        static_cast<quint32>(m_surfaceId),
        m_surfaceWidth,
        m_surfaceHeight);
    if (!m_nativeMetalTexture)
    {
        return false;
    }

    m_rhiTexture = rhi->newTexture(QRhiTexture::BGRA8, QSize(m_surfaceWidth, m_surfaceHeight), 1, {});
    if (!m_rhiTexture)
    {
        clearTextureResources();
        return false;
    }

    const bool imported = m_rhiTexture->createFrom(QRhiTexture::NativeTexture {
        .object = static_cast<quint64>(reinterpret_cast<quintptr>(m_nativeMetalTexture)),
        .layout = 0,
    });
    if (!imported)
    {
        clearTextureResources();
        return false;
    }

    m_sgTexture = window()->createTextureFromRhiTexture(m_rhiTexture);
    if (!m_sgTexture)
    {
        clearTextureResources();
        return false;
    }

    m_textureDirty = false;
    return true;
}

void ZeroCopyViewportItem::updateActiveState(bool next)
{
    if (m_active == next)
    {
        return;
    }

    m_active = next;
    emit activeChanged();
}
