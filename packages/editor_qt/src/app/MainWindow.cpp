#include "MainWindow.h"
#include "EngineProcess.h"
#include "engine/EngineClient.h"
#include "panels/ViewportWidget.h"
#include "panels/SceneTreeWidget.h"
#include "panels/InspectorWidget.h"
#include "util/IconProvider.h"
#include "util/Translator.h"

#include <QAction>
#include <QActionGroup>
#include <QApplication>
#include <QCloseEvent>
#include <QDockWidget>
#include <QLabel>
#include <QMenuBar>
#include <QMessageBox>
#include <QStatusBar>
#include <QTextEdit>
#include <QTimer>
#include <QToolBar>
#include <QTreeView>

MainWindow::MainWindow(QWidget* parent)
    : QMainWindow(parent)
{
    setWindowTitle("Guava Editor");
    resize(1440, 900);
    setMinimumSize(1024, 720);

    // Engine subsystems
    engineClient_ = new EngineClient(this);
    engineProcess_ = new EngineProcess(this);

    setupMenuBar();
    setupToolBar();
    setupDockWidgets();
    setupStatusBar();
    connectEngine();
}

MainWindow::~MainWindow() = default;

// ── Menu Bar ─────────────────────────────────────────────────────────────

void MainWindow::setupMenuBar()
{
    const auto& menus = Translator::menus();
    
    auto* fileMenu = menuBar()->addMenu("&File");
    auto* newSceneAct = fileMenu->addAction(menus.newScene(), QKeySequence::New, [this]() {
        engineClient_->call("scene.createEntity", {{"name", "New Entity"}});
    });
    newSceneAct->setIcon(IconProvider::document());
    
    auto* openAct = fileMenu->addAction(menus.openScene(), QKeySequence::Open, [this]() {
        // TODO: file dialog → scene.load
    });
    openAct->setIcon(IconProvider::openFolder());
    
    auto* saveAct = fileMenu->addAction(menus.saveScene(), QKeySequence::Save, [this]() {
        engineClient_->call("scene.save", {});
    });
    saveAct->setIcon(IconProvider::save());
    
    fileMenu->addSeparator();
    fileMenu->addAction(menus.quit(), QKeySequence::Quit, qApp, &QApplication::quit);

    auto* editMenu = menuBar()->addMenu("&Edit");
    auto* undoAct = editMenu->addAction(menus.undo(), QKeySequence::Undo, [this]() {
        engineClient_->call("editor.undo", {});
    });
    undoAct->setIcon(IconProvider::undo());
    
    auto* redoAct = editMenu->addAction(menus.redo(), QKeySequence::Redo, [this]() {
        engineClient_->call("editor.redo", {});
    });
    redoAct->setIcon(IconProvider::redo());

    auto* viewMenu = menuBar()->addMenu("&View");
    // Dock toggles will be added after dock creation

    auto* helpMenu = menuBar()->addMenu("&Help");
    helpMenu->addAction(menus.about(), [this]() {
        QMessageBox::about(this, "Guava Editor",
            "Guava Editor v0.1.0\nNative Qt Edition");
    });

    // Add dock toggle actions to View menu after docks exist
    QTimer::singleShot(0, this, [this, viewMenu]() {
        if (viewportDock_)  viewMenu->addAction(viewportDock_->toggleViewAction());
        if (sceneDock_)     viewMenu->addAction(sceneDock_->toggleViewAction());
        if (inspectorDock_) viewMenu->addAction(inspectorDock_->toggleViewAction());
        if (consoleDock_)   viewMenu->addAction(consoleDock_->toggleViewAction());
        if (assetDock_)     viewMenu->addAction(assetDock_->toggleViewAction());
    });
}

// ── Tool Bar ─────────────────────────────────────────────────────────────

void MainWindow::setupToolBar()
{
    const auto& toolbar = Translator::toolbar();
    const auto& tooltips = Translator::tooltips();
    
    mainToolBar_ = addToolBar("Main");
    mainToolBar_->setMovable(false);
    mainToolBar_->setIconSize(QSize(20, 20));

    // Gizmo mode group
    auto* translateAct = mainToolBar_->addAction(IconProvider::translate(), toolbar.translate());
    translateAct->setCheckable(true);
    translateAct->setChecked(true);
    translateAct->setShortcut(Qt::Key_W);
    translateAct->setToolTip(tooltips.gizmo().translate());

    auto* rotateAct = mainToolBar_->addAction(IconProvider::rotate(), toolbar.rotate());
    rotateAct->setCheckable(true);
    rotateAct->setShortcut(Qt::Key_E);
    rotateAct->setToolTip(tooltips.gizmo().rotate());

    auto* scaleAct = mainToolBar_->addAction(IconProvider::scale(), toolbar.scale());
    scaleAct->setCheckable(true);
    scaleAct->setShortcut(Qt::Key_R);
    scaleAct->setToolTip(tooltips.gizmo().scale());

    auto* gizmoGroup = new QActionGroup(this);
    gizmoGroup->addAction(translateAct);
    gizmoGroup->addAction(rotateAct);
    gizmoGroup->addAction(scaleAct);
    gizmoGroup->setExclusive(true);

    connect(gizmoGroup, &QActionGroup::triggered, this, [this, translateAct, rotateAct, scaleAct](QAction* action) {
        QString mode = "translate";
        if (action == rotateAct) mode = "rotate";
        else if (action == scaleAct) mode = "scale";
        engineClient_->call("viewport.setGizmoMode", {{"mode", mode}});
    });

    mainToolBar_->addSeparator();

    // Playback controls
    auto* playAct = mainToolBar_->addAction(IconProvider::play(), toolbar.play());
    playAct->setShortcut(Qt::Key_F5);
    playAct->setToolTip({});
    connect(playAct, &QAction::triggered, this, [this]() {
        engineClient_->call("playback.play", {});
    });

    auto* pauseAct = mainToolBar_->addAction(IconProvider::pause(), toolbar.pause());
    pauseAct->setShortcut(Qt::Key_F6);
    connect(pauseAct, &QAction::triggered, this, [this]() {
        engineClient_->call("playback.pause", {});
    });

    auto* stopAct = mainToolBar_->addAction(IconProvider::stop(), toolbar.stop());
    stopAct->setShortcut(Qt::Key_F7);
    connect(stopAct, &QAction::triggered, this, [this]() {
        engineClient_->call("playback.stop", {});
    });
}

// ── Dock Widgets ─────────────────────────────────────────────────────────

static QDockWidget* createDock(const QString& title, QWidget* parent, QWidget* content = nullptr)
{
    auto* dock = new QDockWidget(title, parent);
    dock->setObjectName(title);  // Required for saveState/restoreState
    if (!content) {
        auto* placeholder = new QLabel(title + "\n(Coming soon)");
        placeholder->setAlignment(Qt::AlignCenter);
        content = placeholder;
    }
    dock->setWidget(content);
    return dock;
}

void MainWindow::setupDockWidgets()
{
    const auto& docks = Translator::docks();
    
    // ── Viewport (center) ──
    viewportWidget_ = new ViewportWidget(engineClient_);
    viewportDock_ = createDock(docks.viewport(), this, viewportWidget_);
    setCentralWidget(viewportWidget_);

    // ── Scene Hierarchy (left) ──
    sceneTree_ = new SceneTreeWidget(engineClient_);
    sceneDock_ = createDock(docks.sceneHierarchy(), this, sceneTree_);
    addDockWidget(Qt::LeftDockWidgetArea, sceneDock_);

    // ── Inspector (right) ──
    inspector_ = new InspectorWidget(engineClient_);
    inspectorDock_ = createDock(docks.inspector(), this, inspector_);
    addDockWidget(Qt::RightDockWidgetArea, inspectorDock_);

    // ── Selection sync: scene tree → inspector ──
    connect(sceneTree_, &SceneTreeWidget::selectionSynced,
            inspector_, &InspectorWidget::inspect);

    // ── Console (bottom) ──
    auto* consoleText = new QTextEdit;
    consoleText->setReadOnly(true);
    consoleText->setPlaceholderText("Console output...");
    consoleDock_ = createDock(docks.console(), this, consoleText);
    addDockWidget(Qt::BottomDockWidgetArea, consoleDock_);

    // ── Asset Browser (bottom, tabbed with Console) ──
    assetDock_ = createDock(docks.assetBrowser(), this);
    tabifyDockWidget(consoleDock_, assetDock_);
    consoleDock_->raise();  // Console visible by default

    // Subscribe to console logs
    connect(engineClient_, &EngineClient::consoleLog, this, [consoleText](const QString& level, const QString& message) {
        QString color = "#cdd6f4";  // Text
        if (level == "warning") color = "#f9e2af";  // Yellow
        else if (level == "error") color = "#f38ba8";  // Red

        consoleText->append(
            QStringLiteral("<span style='color:%1'>[%2] %3</span>")
                .arg(color, level, message.toHtmlEscaped()));
    });
}

// ── Status Bar ───────────────────────────────────────────────────────────

void MainWindow::setupStatusBar()
{
    statusLabel_ = new QLabel(tr("Ready"));
    statusBar()->addWidget(statusLabel_, 1);

    engineStatusLabel_ = new QLabel(tr("Engine: Disconnected"));
    engineStatusLabel_->setStyleSheet("color: #f38ba8;");  // Red
    statusBar()->addPermanentWidget(engineStatusLabel_);

    fpsLabel_ = new QLabel(tr("-- FPS"));
    statusBar()->addPermanentWidget(fpsLabel_);

    connect(engineClient_, &EngineClient::connected, this, [this]() {
        engineStatusLabel_->setText(tr("Engine: Connected"));
        engineStatusLabel_->setStyleSheet("color: #a6e3a1;");  // Green
    });

    connect(engineClient_, &EngineClient::disconnected, this, [this]() {
        engineStatusLabel_->setText(tr("Engine: Disconnected"));
        engineStatusLabel_->setStyleSheet("color: #f38ba8;");  // Red
    });

    connect(engineClient_, &EngineClient::viewportMetrics, this,
        [this](double fps, double /*frameTimeMs*/, int drawCalls, int /*triangles*/) {
            fpsLabel_->setText(QStringLiteral("%1 FPS | %2 draws").arg(fps, 0, 'f', 0).arg(drawCalls));
        });
}

// ── Engine Connection ────────────────────────────────────────────────────

void MainWindow::connectEngine()
{
    // Start engine process
    connect(engineProcess_, &EngineProcess::started, this, [this]() {
        statusLabel_->setText(tr("Engine started, waiting for initialization..."));
        // Give engine 2 seconds to fully initialize before attempting WebSocket connection
        QTimer::singleShot(2000, this, [this]() {
            qDebug() << "[MainWindow] Engine initialized delay complete, connecting client...";
            engineClient_->connectToEngine();
        });
    });

    connect(engineProcess_, &EngineProcess::stopped, this, [this](int exitCode) {
        statusLabel_->setText(QStringLiteral("Engine stopped (exit code: %1)").arg(exitCode));
    });

    // Connect to engine RPC
    connect(engineClient_, &EngineClient::connected, this, [this]() {
        statusLabel_->setText(tr("Connected to engine"));
        // Verify connection
        engineClient_->call("editor.ping", {});
    });

    // Start engine (searches for guava-engine binary)
    engineProcess_->start();
    // WebSocket connection happens after engine initialization (in engineProcess_ started signal)
}

// ── Close Event ──────────────────────────────────────────────────────────

void MainWindow::closeEvent(QCloseEvent* event)
{
    // Save window state for next launch
    // QSettings settings;
    // settings.setValue("windowState", saveState());
    // settings.setValue("windowGeometry", saveGeometry());

    engineProcess_->stop();
    event->accept();
}
