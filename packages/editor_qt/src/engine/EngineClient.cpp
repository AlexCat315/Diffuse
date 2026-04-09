#include "EngineClient.h"

#include <QJsonDocument>
#include <QJsonArray>
#include <QDebug>

static constexpr int kRpcTimeoutMs = 30000;
static constexpr int kReconnectMaxDelay = 30;

EngineClient::EngineClient(QObject* parent)
    : QObject(parent)
{
    connect(&socket_, &QWebSocket::connected, this, &EngineClient::onConnected);
    connect(&socket_, &QWebSocket::disconnected, this, &EngineClient::onDisconnected);
    connect(&socket_, &QWebSocket::textMessageReceived, this, &EngineClient::onTextMessage);
    connect(&socket_, &QWebSocket::errorOccurred, this, &EngineClient::onError);

    reconnectTimer_.setSingleShot(true);
    connect(&reconnectTimer_, &QTimer::timeout, this, [this]() {
        if (shouldReconnect_ && socket_.state() == QAbstractSocket::UnconnectedState) {
            socket_.open(QUrl(url_));
        }
    });
}

EngineClient::~EngineClient()
{
    shouldReconnect_ = false;
    socket_.close();

    // Clean up pending calls
    for (auto it = pending_.begin(); it != pending_.end(); ++it) {
        if (it->timer) it->timer->deleteLater();
        if (it->callback) it->callback({}, "Client destroyed");
    }
    pending_.clear();
}

void EngineClient::connectToEngine(const QString& url)
{
    url_ = url;
    shouldReconnect_ = true;
    reconnectAttempts_ = 0;
    socket_.open(QUrl(url));
    qDebug() << "[EngineClient] Connecting to" << url;
}

void EngineClient::disconnect()
{
    shouldReconnect_ = false;
    reconnectTimer_.stop();
    socket_.close();
}

bool EngineClient::isConnected() const
{
    return socket_.state() == QAbstractSocket::ConnectedState;
}

void EngineClient::call(const QString& method, const QJsonObject& params, RpcCallback callback)
{
    int id = nextId_++;

    QJsonObject request;
    request["jsonrpc"] = "2.0";
    request["id"] = id;
    request["method"] = method;
    request["params"] = params;

    QByteArray json = QJsonDocument(request).toJson(QJsonDocument::Compact);

    if (!isConnected()) {
        if (callback) callback({}, "Not connected");
        return;
    }

    // Set up timeout
    QTimer* timer = nullptr;
    if (callback) {
        timer = new QTimer(this);
        timer->setSingleShot(true);
        timer->setInterval(kRpcTimeoutMs);
        connect(timer, &QTimer::timeout, this, [this, id]() {
            auto it = pending_.find(id);
            if (it != pending_.end()) {
                auto cb = it->callback;
                it->timer->deleteLater();
                pending_.erase(it);
                if (cb) cb({}, QStringLiteral("RPC timeout (id=%1)").arg(id));
            }
        });
        timer->start();
    }

    pending_.insert(id, {callback, timer});
    socket_.sendTextMessage(QString::fromUtf8(json));
}

// ── Slots ────────────────────────────────────────────────────────────────

void EngineClient::onConnected()
{
    qDebug() << "[EngineClient] Connected to" << url_;
    reconnectAttempts_ = 0;
    emit connected();
}

void EngineClient::onDisconnected()
{
    qDebug() << "[EngineClient] Disconnected";
    emit disconnected();
    scheduleReconnect();
}

void EngineClient::onTextMessage(const QString& message)
{
    QJsonParseError err;
    QJsonDocument doc = QJsonDocument::fromJson(message.toUtf8(), &err);
    if (err.error != QJsonParseError::NoError) {
        qWarning() << "[EngineClient] Invalid JSON:" << err.errorString();
        return;
    }

    QJsonObject obj = doc.object();

    // JSON-RPC response (has "id")
    if (obj.contains("id") && (obj.contains("result") || obj.contains("error"))) {
        int id = obj["id"].toInt();
        auto it = pending_.find(id);
        if (it != pending_.end()) {
            auto cb = it->callback;
            if (it->timer) {
                it->timer->stop();
                it->timer->deleteLater();
            }
            pending_.erase(it);

            if (cb) {
                if (obj.contains("error")) {
                    QJsonObject errObj = obj["error"].toObject();
                    cb({}, errObj["message"].toString("Unknown RPC error"));
                } else {
                    cb(obj["result"], {});
                }
            }
        }
        return;
    }

    // Engine push event: { "method": "on:xxx", "params": {...} }
    if (obj.contains("method") && !obj.contains("id")) {
        QString method = obj["method"].toString();
        QJsonObject params = obj["params"].toObject();
        dispatchEvent(method, params);
    }
}

void EngineClient::onError(QAbstractSocket::SocketError error)
{
    if (reconnectAttempts_ == 0) {
        qWarning() << "[EngineClient] Socket error:" << error << socket_.errorString();
    }
    scheduleReconnect();
}

// ── Private ──────────────────────────────────────────────────────────────

void EngineClient::scheduleReconnect()
{
    if (!shouldReconnect_ || reconnectTimer_.isActive()) return;

    reconnectAttempts_++;
    int delay = qMin(2 * (1 << qMin(reconnectAttempts_ - 1, 4)), kReconnectMaxDelay);

    if (reconnectAttempts_ <= 3 || (reconnectAttempts_ % 10) == 0) {
        qDebug() << "[EngineClient] Reconnecting in" << delay << "s (attempt" << reconnectAttempts_ << ")";
    }

    reconnectTimer_.start(delay * 1000);
}

void EngineClient::dispatchEvent(const QString& method, const QJsonObject& params)
{
    if (method == "on:scene.changed") {
        int revision = params["revision"].toInt();
        QVector<int> ids;
        for (auto v : params["entityIds"].toArray())
            ids.append(v.toInt());
        emit sceneChanged(revision, ids);
    }
    else if (method == "on:selection.changed") {
        QVector<int> ids;
        for (auto v : params["entityIds"].toArray())
            ids.append(v.toInt());
        emit selectionChanged(ids);
    }
    else if (method == "on:console.log") {
        emit consoleLog(params["level"].toString(), params["message"].toString());
    }
    else if (method == "on:console.logs") {
        for (auto entry : params["entries"].toArray()) {
            QJsonObject e = entry.toObject();
            emit consoleLog(e["level"].toString(), e["message"].toString());
        }
    }
    else if (method == "on:viewport.metrics") {
        emit viewportMetrics(
            params["fps"].toDouble(),
            params["frameTimeMs"].toDouble(),
            params["drawCalls"].toInt(),
            params["triangles"].toInt());
    }
    else if (method == "on:playback.stateChanged") {
        emit playbackStateChanged(params["state"].toString());
    }
    else if (method == "on:editor.historyChanged") {
        emit historyChanged(params["cursor"].toInt(), params["totalEntries"].toInt());
    }
}
