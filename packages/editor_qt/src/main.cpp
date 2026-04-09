#include "app/MainWindow.h"
#include "util/Theme.h"
#include "util/Translator.h"
#include <QApplication>
#include <QLocale>

int main(int argc, char* argv[])
{
    QApplication app(argc, argv);
    app.setApplicationName("Guava Editor");
    app.setApplicationVersion("0.1.0");
    app.setOrganizationName("Guava");

    // Detect system language and set translator
    QString systemLanguage = QLocale::system().name();  // "en_US", "zh_CN", etc.
    if (systemLanguage.startsWith("zh")) {
        Translator::setLanguage("zh_CN");
    } else {
        Translator::setLanguage("en_US");
    }

    Theme::apply(&app);

    MainWindow window;
    window.show();

    return app.exec();
}
