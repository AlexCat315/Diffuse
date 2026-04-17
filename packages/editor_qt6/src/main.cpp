#include <QApplication>
#include <QStringList>

#include "MainWindow.h"

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    const QStringList args = app.arguments();
    if (args.contains("--self-test"))
    {
        // Smoke mode for CI/local validation: verify app bootstrap without opening UI.
        return 0;
    }

    MainWindow window;
    window.show();

    return app.exec();
}
