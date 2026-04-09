#pragma once

#include <QObject>
#include <QWebSocket>
#include <QJsonObject>
#include <QJsonValue>
#include <QHash>
#include <QTimer>
#include <functional>

class EngineClient : public QObject
{
    Q_OBJECT

public:
    explicit EngineClient(QObject* parent = nullptr);
    ~EngineClient() override;

    void connectToEngine(const QString& url = "ws://127.0.0.1:9100");
    void disconnect();
    bool isConnected() const;

    /// Async JSON-RPC call. Callback receives (result, errorString).
    /// If errorString is empty, result is valid.
    using RpcCallback = std::function<void(const QJsonValue& result, const QString& error)>;
    void call(const QString& method, const QJsonObject& params = {}, RpcCallback callback = nullptr);

signals:
    void connected();
    void disconnected();

    // Typed engine events
    void sceneChanged(int revision, QVector<int> entityIds);
    void selectionChanged(QVector<int> entityIds);
    void consoleLog(const QString& level, const QString& message);
    void viewportMetrics(double fps, double frameTimeMs, int drawCalls, int triangles);
    void playbackStateChanged(const QString& state);
    void historyChanged(int cursor, int totalEntries);

private slots:
    void onConnected();
    void onDisconnected();
    void onTextMessage(const QString& message);
    void onError(QAbstractSocket::SocketError error);

private:
    void scheduleReconnect();
    void dispatchEvent(const QString& method, const QJsonObject& params);

    QWebSocket socket_;
    QString url_;
    int nextId_ = 1;
    bool shouldReconnect_ = true;
    int reconnectAttempts_ = 0;
    QTimer reconnectTimer_;

    struct PendingCall {
        RpcCallback callback;
        QTimer* timer = nullptr;
    };
    QHash<int, PendingCall> pending_;
};
