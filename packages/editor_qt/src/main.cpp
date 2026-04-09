#include "app/MainWindow.h"
#include "util/Theme.h"
#include <QApplication>

int main(int argc, char* argv[])
{
    QApplication app(argc, argv);
    app.setApplicationName("Guava Editor");
    app.setApplicationVersion("0.1.0");
    app.setOrganizationName("Guava");

    Theme::apply(&app);

    MainWindow window;
    window.show();

    return app.exec();
}
