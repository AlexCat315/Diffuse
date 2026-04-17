#include "MainWindow.h"

#include <QDockWidget>
#include <QLabel>
#include <QMenuBar>
#include <QStatusBar>
#include <QTextEdit>
#include <QToolBar>

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent)
{
    setWindowTitle("Guava Editor (Qt6)");
    resize(1280, 800);

    auto *viewport = new QTextEdit(this);
    viewport->setReadOnly(true);
    viewport->setPlainText("Viewport Placeholder\n\nNext step: embed Engine viewport host here.");
    setCentralWidget(viewport);

    auto *sceneDock = new QDockWidget("Scene", this);
    sceneDock->setObjectName("scene_dock");
    sceneDock->setWidget(new QLabel("Scene Hierarchy Placeholder", sceneDock));
    addDockWidget(Qt::LeftDockWidgetArea, sceneDock);

    auto *inspectorDock = new QDockWidget("Inspector", this);
    inspectorDock->setObjectName("inspector_dock");
    inspectorDock->setWidget(new QLabel("Inspector Placeholder", inspectorDock));
    addDockWidget(Qt::RightDockWidgetArea, inspectorDock);

    auto *consoleDock = new QDockWidget("Console", this);
    consoleDock->setObjectName("console_dock");
    consoleDock->setWidget(new QLabel("Console Placeholder", consoleDock));
    addDockWidget(Qt::BottomDockWidgetArea, consoleDock);

    auto *toolbar = addToolBar("Playback");
    toolbar->setObjectName("playback_toolbar");
    toolbar->addAction("Play");
    toolbar->addAction("Pause");
    toolbar->addAction("Stop");

    auto *fileMenu = menuBar()->addMenu("File");
    fileMenu->addAction("Quit", this, &QWidget::close);

    statusBar()->showMessage("Qt6 minimal shell ready");
}
