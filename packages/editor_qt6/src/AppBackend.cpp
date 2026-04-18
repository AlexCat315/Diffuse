#include "AppBackend.h"

#include <QJsonObject>
#include <QJsonValue>

void AppBackend::pushViewportRect()
{
    if (!m_engineConnected || !m_viewportRect.isValid())
    {
        return;
    }

    QJsonObject rect;
    rect["x"] = m_viewportRect.x();
    rect["y"] = m_viewportRect.y();
    rect["width"] = m_viewportRect.width();
    rect["height"] = m_viewportRect.height();
    m_rpc.invoke(QStringLiteral("viewport.setRect"), rect);
}

AppBackend::AppBackend(const AppOptions &options, QObject *parent)
    : QObject(parent)
    , m_options(options)
{
    connect(&m_rpc, &EngineRpcClient::connected, this, [this]() {
        m_engineConnected = true;
        m_totalFrames = 0;
        m_lastFrames = 0;
        m_fps = 0.0;
        m_remoteFps = 0.0;
        m_lastRemoteFpsMs = -1;
        emit fpsChanged();
        m_nativeViewportAttached = false;
        emit nativeViewportAttachedChanged();
        m_zeroCopyReady = false;
        emit zeroCopyReadyChanged();

        m_statusText = QStringLiteral("Engine RPC connected");
        emit statusTextChanged();

        // Request unlimited frame pacing in editor-server mode.
        QJsonObject frameRate;
        frameRate["fps"] = 0;
        m_rpc.invoke(QStringLiteral("viewport.setFrameRate"), frameRate);

        pushViewportRect();
        m_rpc.invoke(QStringLiteral("viewport.getSurfaceId"));

        QTimer::singleShot(200, this, [this]() {
            if (m_engineConnected)
            {
                m_captureTimer.start();
                m_surfaceProbeTimer.start();
            }
        });
    });
    connect(&m_rpc, &EngineRpcClient::disconnected, this, [this]() {
        m_engineConnected = false;
        m_nativeViewportAttached = false;
        emit nativeViewportAttachedChanged();
        m_zeroCopyReady = false;
        emit zeroCopyReadyChanged();
        m_statusText = QStringLiteral("Engine RPC disconnected");
        emit statusTextChanged();
        m_captureTimer.stop();
        m_surfaceProbeTimer.stop();
    });
    connect(&m_rpc, &EngineRpcClient::errorOccurred, this, [this](const QString &message) {
        m_engineConnected = false;
        m_nativeViewportAttached = false;
        emit nativeViewportAttachedChanged();
        m_zeroCopyReady = false;
        emit zeroCopyReadyChanged();
        m_statusText = QStringLiteral("Engine RPC error: ") + message;
        emit statusTextChanged();
        m_captureTimer.stop();
        m_surfaceProbeTimer.stop();
    });
    connect(&m_rpc, &EngineRpcClient::resultReceived, this, [this](const QString &method, const QJsonValue &result) {
        if (method == QStringLiteral("viewport.getSurfaceId") && result.isObject())
        {
            const QJsonObject obj = result.toObject();
            const qint64 surfaceId = obj.value(QStringLiteral("surfaceId")).toInteger(0);
            const int width = obj.value(QStringLiteral("width")).toInt(0);
            const int height = obj.value(QStringLiteral("height")).toInt(0);

            m_surfaceId = surfaceId;
            m_surfaceWidth = width;
            m_surfaceHeight = height;

            const bool surfaceReady = surfaceId > 0 && width > 0 && height > 0;
            if (m_zeroCopyReady != surfaceReady)
            {
                m_zeroCopyReady = surfaceReady;
                emit zeroCopyReadyChanged();
            }

            if (m_nativeViewportAttached != surfaceReady)
            {
                m_nativeViewportAttached = surfaceReady;
                emit nativeViewportAttachedChanged();
            }

            if (surfaceReady)
            {
                m_captureTimer.stop();
                m_statusText = QStringLiteral("Engine RPC connected (IOSurface zero-copy in SceneGraph)");
                emit statusTextChanged();
            }
            else if (m_engineConnected)
            {
                if (!m_captureTimer.isActive())
                {
                    m_captureTimer.start();
                }

                m_statusText = QStringLiteral("Engine RPC connected (waiting IOSurface, screenshot fallback)");
                emit statusTextChanged();
            }
        }

        if (method != QStringLiteral("viewport.screenshot") || !result.isObject())
        {
            return;
        }

        const QString dataUri = result.toObject().value(QStringLiteral("dataUri")).toString();
        if (dataUri.isEmpty() || dataUri == m_frameDataUrl)
        {
            return;
        }

        m_frameDataUrl = dataUri;
        emit frameDataUrlChanged();
    });
    connect(&m_rpc, &EngineRpcClient::notificationReceived, this, [this](const QString &method, const QJsonValue &params) {
        if (method == QStringLiteral("on:viewport.frameReady"))
        {
            ++m_totalFrames;
            return;
        }

        if (method == QStringLiteral("on:viewport.metrics"))
        {
            if (!params.isObject())
            {
                return;
            }

            const QJsonObject metrics = params.toObject();
            const double nextFps = metrics.value(QStringLiteral("fps")).toDouble(0.0);
            if (!m_benchmarkClock.isValid())
            {
                m_benchmarkClock.start();
            }
            m_lastRemoteFpsMs = m_benchmarkClock.elapsed();

            if (nextFps > 0.0)
            {
                m_remoteFps = nextFps;
                m_fps = nextFps;
                emit fpsChanged();
            }
        }
    });
    m_rpc.connectToEngine(m_options.engineUrl);

    m_statsTimer.setTimerType(Qt::PreciseTimer);
    m_statsTimer.setInterval(1000);
    connect(&m_statsTimer, &QTimer::timeout, this, &AppBackend::onStatsTick);
    m_statsTimer.start();

    m_captureTimer.setTimerType(Qt::CoarseTimer);
    m_captureTimer.setInterval(100);
    connect(&m_captureTimer, &QTimer::timeout, this, [this]() {
        m_rpc.invoke(QStringLiteral("viewport.screenshot"));
    });

    m_surfaceProbeTimer.setTimerType(Qt::CoarseTimer);
    m_surfaceProbeTimer.setInterval(1000);
    connect(&m_surfaceProbeTimer, &QTimer::timeout, this, [this]() {
        if (m_engineConnected && !m_zeroCopyReady)
        {
            m_rpc.invoke(QStringLiteral("viewport.getSurfaceId"));
        }
    });

    m_benchmarkClock.start();

    if (m_options.benchmarkMode)
    {
        m_benchmarkTimer.setSingleShot(true);
        connect(&m_benchmarkTimer, &QTimer::timeout, this, &AppBackend::onBenchmarkTimeout);
        m_benchmarkTimer.start(m_options.benchmarkSeconds * 1000);
    }
}

void AppBackend::frameRendered()
{
    ++m_totalFrames;
}

void AppBackend::updateViewportRect(int x, int y, int width, int height)
{
    if (width <= 0 || height <= 0)
    {
        return;
    }

    const QRect next(x, y, width, height);
    if (next == m_viewportRect)
    {
        return;
    }

    m_viewportRect = next;
    pushViewportRect();
}

void AppBackend::reportOverlayPulse()
{
    if (!m_benchmarkClock.isValid())
    {
        m_benchmarkClock.start();
    }

    m_lastOverlayPulseMs = m_benchmarkClock.elapsed();
}

void AppBackend::sendViewportInput(const QString &type,
                                   double x,
                                   double y,
                                   int button,
                                   int key,
                                   bool shift,
                                   bool ctrl,
                                   bool alt,
                                   int deltaX,
                                   int deltaY)
{
    if (!m_engineConnected)
    {
        return;
    }

    QJsonObject payload;
    payload["type"] = type;
    payload["x"] = x;
    payload["y"] = y;
    payload["button"] = button;
    payload["key"] = key;
    payload["shift"] = shift;
    payload["ctrl"] = ctrl;
    payload["alt"] = alt;
    payload["deltaX"] = deltaX;
    payload["deltaY"] = deltaY;

    m_rpc.invoke(QStringLiteral("viewport.sendInput"), payload);
}

void AppBackend::onStatsTick()
{
    const qint64 frameDelta = m_totalFrames - m_lastFrames;
    m_lastFrames = m_totalFrames;

    const qint64 nowMs = m_benchmarkClock.isValid() ? m_benchmarkClock.elapsed() : 0;
    const bool remoteFresh = m_lastRemoteFpsMs >= 0 && (nowMs - m_lastRemoteFpsMs) <= 2000;
    m_fps = remoteFresh ? m_remoteFps : static_cast<double>(frameDelta);
    emit fpsChanged();

    pushViewportRect();
}

void AppBackend::onBenchmarkTimeout()
{
    const qint64 elapsedMs = m_benchmarkClock.elapsed();
    if (elapsedMs > 0 && m_fps <= 0.0)
    {
        m_fps = (static_cast<double>(m_totalFrames) * 1000.0) / static_cast<double>(elapsedMs);
        emit fpsChanged();
    }

    const bool overlayPulseSeen = m_lastOverlayPulseMs >= 0 && (elapsedMs - m_lastOverlayPulseMs) <= 1500;
    const bool overlayOk = overlayPulseSeen;
    emit benchmarkFinished(m_fps, overlayOk, m_engineConnected);
}
