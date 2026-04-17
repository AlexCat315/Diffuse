#include "EngineRpcClient.h"

#include <QJsonDocument>
#include <QJsonObject>

EngineRpcClient::EngineRpcClient(QObject *parent)
    : QObject(parent)
{
    connect(&m_socket, &QWebSocket::connected, this, &EngineRpcClient::connected);
    connect(&m_socket, &QWebSocket::disconnected, this, &EngineRpcClient::disconnected);
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
    message["id"] = m_nextId++;
    message["method"] = method;
    message["params"] = params;

    m_socket.sendTextMessage(QString::fromUtf8(QJsonDocument(message).toJson(QJsonDocument::Compact)));
}
