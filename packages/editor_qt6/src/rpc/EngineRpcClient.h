#pragma once

#include <QObject>
#include <QJsonObject>
#include <QUrl>
#include <QWebSocket>

class EngineRpcClient final : public QObject
{
    Q_OBJECT

public:
    explicit EngineRpcClient(QObject *parent = nullptr);

    void connectToEngine(const QUrl &url);
    void invoke(const QString &method, const QJsonObject &params = {});

signals:
    void connected();
    void disconnected();
    void errorOccurred(const QString &message);

private:
    QWebSocket m_socket;
    qint64 m_nextId {1};
};
