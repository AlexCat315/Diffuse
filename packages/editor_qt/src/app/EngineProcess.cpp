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

    // Engine needs to run from project root to find assets/
    QDir projectRoot = QDir(QCoreApplication::applicationDirPath());
    // Navigate from: /path/to/build/GuavaEditor.app/Contents/MacOS
    // to: /path/to/workspace (project root)
    for (int i = 0; i < 6; ++i) {
        projectRoot.cdUp();
    }

    qDebug() << "[EngineProcess] Setting working directory to:" << projectRoot.absolutePath();
    process_->setWorkingDirectory(projectRoot.absolutePath());

    qDebug() << "[EngineProcess] Starting:" << binary << "with --editor-server";
    // Start in headless editor-server mode (WebSocket RPC on port 9100, no SDL window)
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
    // Check if we're in the editor_qt build directory
    // packages/editor_qt/build/GuavaEditor.app/Contents/MacOS/GuavaEditor
    // → ../../../../packages/engine/zig-out/bin/guava-engine
    QDir dir(appDir);
    // Navigate up from Contents/MacOS to workspace root:
    // Contents/MacOS (0) -> GuavaEditor.app (1) -> build (2) -> packages (3) -> editor_qt (4) -> packages (5) -> workspace root (6)
    for (int i = 0; i < 6; ++i) {
        dir.cdUp();
    }
    QString candidate = dir.absoluteFilePath("packages/engine/zig-out/bin/guava-engine");
    if (QFileInfo::exists(candidate)) return candidate;

    // Also check the build directory we just found (where we built the engine)
    candidate = dir.absoluteFilePath("packages/engine/build/zig-out/bin/guava-engine");
    if (QFileInfo::exists(candidate)) return candidate;

    for (const auto& path : candidates) {
        if (QFileInfo::exists(path)) return path;
    }

    // Fallback: assume it's in PATH
    return "guava-engine";
}
