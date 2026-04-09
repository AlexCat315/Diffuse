#pragma once

#include <QMainWindow>
#include <QDockWidget>
#include <QMenuBar>
#include <QToolBar>
#include <QStatusBar>
#include <QLabel>

class EngineClient;
class EngineProcess;
class ViewportWidget;
class SceneTreeWidget;
class InspectorWidget;

class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);
    ~MainWindow() override;

protected:
    void closeEvent(QCloseEvent* event) override;

private:
    void setupMenuBar();
    void setupToolBar();
    void setupDockWidgets();
    void setupStatusBar();
    void connectEngine();

    // Engine
    EngineProcess* engineProcess_ = nullptr;
    EngineClient*  engineClient_  = nullptr;

    // Toolbar
    QToolBar* mainToolBar_ = nullptr;

    // Status bar
    QLabel* statusLabel_ = nullptr;
    QLabel* engineStatusLabel_ = nullptr;
    QLabel* fpsLabel_ = nullptr;

    // Dock widgets (Phase 0: placeholders)
    QDockWidget* viewportDock_ = nullptr;
    ViewportWidget* viewportWidget_ = nullptr;
    QDockWidget* sceneDock_ = nullptr;
    SceneTreeWidget* sceneTree_ = nullptr;
    QDockWidget* inspectorDock_ = nullptr;
    InspectorWidget* inspector_ = nullptr;
    QDockWidget* consoleDock_ = nullptr;
    QDockWidget* assetDock_ = nullptr;
};
