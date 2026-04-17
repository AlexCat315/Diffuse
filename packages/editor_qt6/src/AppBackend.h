#pragma once

#include <QObject>
#include <QElapsedTimer>
#include <QTimer>
#include <QUrl>

#include "rpc/EngineRpcClient.h"

struct AppOptions
{
    bool benchmarkMode {false};
    int benchmarkSeconds {5};
    QUrl engineUrl {QStringLiteral("ws://127.0.0.1:9100")};
};

class AppBackend final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(double fps READ fps NOTIFY fpsChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusTextChanged)

public:
    explicit AppBackend(const AppOptions &options, QObject *parent = nullptr);

    double fps() const { return m_fps; }
    QString statusText() const { return m_statusText; }

    Q_INVOKABLE void frameRendered();

signals:
    void fpsChanged();
    void statusTextChanged();
    void benchmarkFinished(double fps, bool overlayOk);

private:
    void onStatsTick();
    void onBenchmarkTimeout();

    AppOptions m_options;
    EngineRpcClient m_rpc;
    QTimer m_renderTimer;
    QTimer m_statsTimer;
    QTimer m_benchmarkTimer;
    QElapsedTimer m_benchmarkClock;

    qint64 m_totalFrames {0};
    qint64 m_lastFrames {0};
    double m_fps {0.0};
    QString m_statusText {QStringLiteral("Initializing...")};
};
