#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QLocale>
#include "app/EngineProcess.h"
#include "engine/EngineClient.h"
#include "util/Translator.h"
#include "util/TranslatorQML.h"
#include "util/SceneModel.h"
#include "theme/Theme.h"
#include "panels/MetalViewportItem.h"

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    app.setApplicationName("Guava Editor");
    app.setApplicationVersion("0.1.0");
    app.setOrganizationName("Guava");

    // Detect system language and set translator
    QString systemLanguage = QLocale::system().name();
    if (systemLanguage.startsWith("zh")) {
        Translator::setLanguage("zh_CN");
    } else {
        Translator::setLanguage("en_US");
    }

    // Create engine backend
    auto* engineProcess = new EngineProcess(&app);
    auto* engineClient = new EngineClient(&app);
    auto* translatorQML = new TranslatorQML(&app);
    auto* sceneModel = new SceneModel(engineClient, &app);

    // Setup QML engine
    QQmlApplicationEngine engine;
    
    // Register C++ objects to QML context
    engine.rootContext()->setContextProperty("EngineClient", engineClient);
    engine.rootContext()->setContextProperty("EngineProcess", engineProcess);
    engine.rootContext()->setContextProperty("Translator", translatorQML);
    engine.rootContext()->setContextProperty("SceneModel", sceneModel);
    
    // Register custom QML types
    qmlRegisterType<MetalViewportItem>("GuavaEditor", 1, 0, "MetalViewportItem");

    // Load main QML file
    const QUrl url(QStringLiteral("qrc:/qml/main.qml"));
    engine.load(url);

    if (engine.rootObjects().isEmpty())
        return -1;

    // Start engine process
    engineProcess->start();

    return app.exec();
}
