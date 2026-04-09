#include "EngineProcess.h"

#include <QCoreApplication>
#include <QDir>
#include <QDebug>
#include <QFileInfo>

EngineProcess::EngineProcess(QObject* parent)
    : QObject(parent)
    , process_(new QProcess(this))
{
    process_->setProcessChannelMode(QProcess::MergedChannels);

    connect(process_, &QProcess::started, this, [this]() {
        qDebug() << "[EngineProcess] Engine started (pid:" << process_->processId() << ")";
        emit started();
    });

    connect(process_, &QProcess::finished, this, [this](int exitCode, QProcess::ExitStatus status) {
        qDebug() << "[EngineProcess] Engine stopped, exit code:" << exitCode
                 << (status == QProcess::CrashExit ? "(crashed)" : "");
        emit stopped(exitCode);
    });

    connect(process_, &QProcess::readyReadStandardOutput, this, [this]() {
        while (process_->canReadLine()) {
            QString line = QString::fromUtf8(process_->readLine()).trimmed();
            if (!line.isEmpty()) {
                emit output(line);
            }
        }
    });

    connect(process_, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        qWarning() << "[EngineProcess] Error:" << error << process_->errorString();
    });
}

EngineProcess::~EngineProcess()
{
    stop();
}

void EngineProcess::start()
{
    if (process_->state() != QProcess::NotRunning) {
        qDebug() << "[EngineProcess] Already running";
        return;
    }

    QString binary = findEngineBinary();
    if (binary.isEmpty()) {
        qWarning() << "[EngineProcess] Could not find guava-engine binary";
        return;
    }

    qDebug() << "[EngineProcess] Starting:" << binary;
    process_->start(binary, {"--editor-server"});
}

void EngineProcess::stop()
{
    if (process_->state() == QProcess::NotRunning) return;

    qDebug() << "[EngineProcess] Stopping engine...";
    process_->terminate();
    if (!process_->waitForFinished(5000)) {
        qWarning() << "[EngineProcess] Engine did not stop gracefully, killing";
        process_->kill();
        process_->waitForFinished(2000);
    }
}

bool EngineProcess::isRunning() const
{
    return process_->state() == QProcess::Running;
}

QString EngineProcess::findEngineBinary() const
{
    // Search paths (in priority order):
    // 1. Next to the editor binary
    // 2. Engine build output (development)
    // 3. PATH

    QStringList candidates;

    // Next to editor binary
    QString appDir = QCoreApplication::applicationDirPath();
    candidates << appDir + "/guava-engine";

    // Engine build output (from workspace root)
    // packages/editor_qt/build/GuavaEditor.app/Contents/MacOS/GuavaEditor
    // → packages/engine/zig-out/bin/guava-engine
    QDir dir(appDir);
    // Navigate up from build dir to workspace root
    for (int i = 0; i < 6; ++i) {
        QString candidate = dir.absoluteFilePath("packages/engine/zig-out/bin/guava-engine");
        if (QFileInfo::exists(candidate)) return candidate;
        dir.cdUp();
    }

    for (const auto& path : candidates) {
        if (QFileInfo::exists(path)) return path;
    }

    // Fallback: assume it's in PATH
    return "guava-engine";
}
