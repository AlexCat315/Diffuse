#include "EngineRpcClient.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>

EngineRpcClient::EngineRpcClient(QObject *parent)
    : QObject(parent)
{
    connect(&m_socket, &QWebSocket::connected, this, &EngineRpcClient::connected);
    connect(&m_socket, &QWebSocket::disconnected, this, &EngineRpcClient::disconnected);
    connect(&m_socket, &QWebSocket::textMessageReceived, this, &EngineRpcClient::onTextMessage);
    connect(&m_socket, &QWebSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
        emit errorOccurred(m_socket.errorString());
    });
}

void EngineRpcClient::connectToEngine(const QUrl &url)
{
    m_socket.open(url);
}

void EngineRpcClient::invoke(const QString &method, const QJsonObject &params)
{
    if (m_socket.state() != QAbstractSocket::ConnectedState)
    {
        return;
    }

    QJsonObject message;
    message["jsonrpc"] = QStringLiteral("2.0");
    const qint64 id = m_nextId++;
    message["id"] = id;
    message["method"] = method;
    message["params"] = params;

    m_pendingMethods.insert(id, method);

    m_socket.sendTextMessage(QString::fromUtf8(QJsonDocument(message).toJson(QJsonDocument::Compact)));
}

void EngineRpcClient::onTextMessage(const QString &text)
{
    const QJsonDocument doc = QJsonDocument::fromJson(text.toUtf8());
    if (!doc.isObject())
    {
        return;
    }

    const QJsonObject obj = doc.object();

    if (obj.contains("id"))
    {
        const qint64 id = obj.value("id").toInteger(-1);
        const QString method = m_pendingMethods.take(id);
        if (!method.isEmpty())
        {
            emit resultReceived(method, obj.value("result"));
        }
        return;
    }

    if (obj.contains("method"))
    {
        emit notificationReceived(obj.value("method").toString(), obj.value("params"));
    }
}
