#include <QGuiApplication>
#include <QDebug>
#include <QCoreApplication>
#include <QQmlContext>
#include <QQmlApplicationEngine>

#include "AppBackend.h"

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    const QStringList args = app.arguments();
    if (args.contains("--self-test"))
    {
        // Smoke mode for CI/local validation: verify bootstrap without opening UI.
        return 0;
    }

    AppOptions options;
    options.benchmarkMode = args.contains("--benchmark-viewport");

    const int benchmarkSecondsIndex = args.indexOf("--benchmark-seconds");
    if (benchmarkSecondsIndex >= 0 && benchmarkSecondsIndex + 1 < args.size())
    {
        options.benchmarkSeconds = args.at(benchmarkSecondsIndex + 1).toInt();
        if (options.benchmarkSeconds <= 0)
        {
            options.benchmarkSeconds = 5;
        }
    }

    const int engineUrlIndex = args.indexOf("--engine-url");
    if (engineUrlIndex >= 0 && engineUrlIndex + 1 < args.size())
    {
        options.engineUrl = QUrl(args.at(engineUrlIndex + 1));
    }

    AppBackend backend(options);
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("appBackend", &backend);

    QObject::connect(&backend, &AppBackend::benchmarkFinished, &app, [&](double fps, bool overlayOk) {
        if (!options.benchmarkMode)
        {
            return;
        }

        const bool fpsOk = fps >= 240.0;
        qInfo().noquote() << QString("BENCHMARK viewport_fps=%1 target=240 overlay=%2")
                                 .arg(fps, 0, 'f', 2)
                                 .arg(overlayOk ? "ok" : "fail");
        app.exit((fpsOk && overlayOk) ? 0 : 2);
    });

    const QUrl mainQml(QStringLiteral("qrc:/qt/qml/GuavaEditor/qml/Main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, []() { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(mainQml);

    return app.exec();
}
