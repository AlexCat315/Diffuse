#pragma once

#include <QObject>
#include <QElapsedTimer>
#include <QRect>
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
    Q_PROPERTY(QString frameDataUrl READ frameDataUrl NOTIFY frameDataUrlChanged)
    Q_PROPERTY(bool zeroCopyReady READ zeroCopyReady NOTIFY zeroCopyReadyChanged)
    Q_PROPERTY(bool nativeViewportAttached READ nativeViewportAttached NOTIFY nativeViewportAttachedChanged)
    Q_PROPERTY(qint64 surfaceId READ surfaceId NOTIFY zeroCopyReadyChanged)
    Q_PROPERTY(int surfaceWidth READ surfaceWidth NOTIFY zeroCopyReadyChanged)
    Q_PROPERTY(int surfaceHeight READ surfaceHeight NOTIFY zeroCopyReadyChanged)

public:
    explicit AppBackend(const AppOptions &options, QObject *parent = nullptr);

    double fps() const { return m_fps; }
    QString statusText() const { return m_statusText; }
    QString frameDataUrl() const { return m_frameDataUrl; }
    bool zeroCopyReady() const { return m_zeroCopyReady; }
    bool nativeViewportAttached() const { return m_nativeViewportAttached; }
    qint64 surfaceId() const { return m_surfaceId; }
    int surfaceWidth() const { return m_surfaceWidth; }
    int surfaceHeight() const { return m_surfaceHeight; }

    Q_INVOKABLE void frameRendered();
    Q_INVOKABLE void updateViewportRect(int x, int y, int width, int height);
    Q_INVOKABLE void reportOverlayPulse();
    Q_INVOKABLE void sendViewportInput(const QString &type,
                                       double x,
                                       double y,
                                       int button,
                                       int key,
                                       bool shift,
                                       bool ctrl,
                                       bool alt,
                                       int deltaX = 0,
                                       int deltaY = 0);

signals:
    void fpsChanged();
    void statusTextChanged();
    void frameDataUrlChanged();
    void zeroCopyReadyChanged();
    void nativeViewportAttachedChanged();
    void benchmarkFinished(double fps, bool overlayOk, bool engineConnected);

private:
    void pushViewportRect();
    void onStatsTick();
    void onBenchmarkTimeout();

    AppOptions m_options;
    EngineRpcClient m_rpc;
    QTimer m_statsTimer;
    QTimer m_captureTimer;
    QTimer m_surfaceProbeTimer;
    QTimer m_benchmarkTimer;
    QElapsedTimer m_benchmarkClock;

    qint64 m_totalFrames {0};
    qint64 m_lastFrames {0};
    double m_fps {0.0};
    bool m_engineConnected {false};
    bool m_nativeViewportAttached {false};
    bool m_zeroCopyReady {false};
    QRect m_viewportRect;
    qint64 m_lastOverlayPulseMs {-1};
    qint64 m_lastRemoteFpsMs {-1};
    double m_remoteFps {0.0};
    qint64 m_surfaceId {0};
    int m_surfaceWidth {0};
    int m_surfaceHeight {0};
    QString m_frameDataUrl;
    QString m_statusText {QStringLiteral("Initializing...")};
};
