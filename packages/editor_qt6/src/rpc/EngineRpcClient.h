#pragma once

#include <QObject>
#include <QJsonObject>
#include <QJsonValue>
#include <QHash>
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
    void resultReceived(const QString &method, const QJsonValue &result);
    void notificationReceived(const QString &method, const QJsonValue &params);

private:
    void onTextMessage(const QString &text);

    QWebSocket m_socket;
    qint64 m_nextId {1};
    QHash<qint64, QString> m_pendingMethods;
};
