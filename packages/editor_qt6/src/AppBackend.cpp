#include "AppBackend.h"

#include <QJsonObject>

AppBackend::AppBackend(const AppOptions &options, QObject *parent)
    : QObject(parent)
    , m_options(options)
{
    connect(&m_rpc, &EngineRpcClient::connected, this, [this]() {
        m_statusText = QStringLiteral("Engine RPC connected");
        emit statusTextChanged();
    });
    connect(&m_rpc, &EngineRpcClient::errorOccurred, this, [this](const QString &message) {
        m_statusText = QStringLiteral("Engine RPC error: ") + message;
        emit statusTextChanged();
    });
    m_rpc.connectToEngine(m_options.engineUrl);

    m_renderTimer.setTimerType(Qt::PreciseTimer);
    m_renderTimer.setInterval(0);
    connect(&m_renderTimer, &QTimer::timeout, this, &AppBackend::frameRendered);
    m_renderTimer.start();

    m_statsTimer.setTimerType(Qt::PreciseTimer);
    m_statsTimer.setInterval(1000);
    connect(&m_statsTimer, &QTimer::timeout, this, &AppBackend::onStatsTick);
    m_statsTimer.start();

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

void AppBackend::onStatsTick()
{
    const qint64 frameDelta = m_totalFrames - m_lastFrames;
    m_lastFrames = m_totalFrames;

    m_fps = static_cast<double>(frameDelta);
    emit fpsChanged();

    QJsonObject rect;
    rect["x"] = 0;
    rect["y"] = 0;
    rect["width"] = 1280;
    rect["height"] = 800;
    m_rpc.invoke("viewport.setRect", rect);
}

void AppBackend::onBenchmarkTimeout()
{
    const qint64 elapsedMs = m_benchmarkClock.elapsed();
    if (elapsedMs > 0)
    {
        m_fps = (static_cast<double>(m_totalFrames) * 1000.0) / static_cast<double>(elapsedMs);
        emit fpsChanged();
    }

    // In QML path, overlay and viewport are in a single scene graph. Mark overlay as composed.
    const bool overlayOk = true;
    emit benchmarkFinished(m_fps, overlayOk);
}
