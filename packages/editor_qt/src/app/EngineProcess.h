#pragma once

#include <QObject>
#include <QProcess>

class EngineProcess : public QObject
{
    Q_OBJECT

public:
    explicit EngineProcess(QObject* parent = nullptr);
    ~EngineProcess() override;

    void start();
    void stop();
    bool isRunning() const;

signals:
    void started();
    void stopped(int exitCode);
    void output(const QString& line);

private:
    QString findEngineBinary() const;

    QProcess* process_ = nullptr;
};
