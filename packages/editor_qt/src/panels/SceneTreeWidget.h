#pragma once

#include <QTreeView>
#include <QStandardItemModel>
#include <QJsonArray>
#include <QJsonObject>
#include <QMenu>

class EngineClient;

/// SceneTreeWidget — Displays the entity hierarchy from the engine.
///
/// Backed by scene.getHierarchy RPC, auto-refreshes on scene changes.
/// Supports: selection sync, rename, delete, reparent (drag-drop), create entity.
class SceneTreeWidget : public QTreeView
{
    Q_OBJECT

public:
    explicit SceneTreeWidget(EngineClient* engine, QWidget* parent = nullptr);

    /// Force a full tree refresh from engine
    void refresh();

signals:
    void selectionSynced(QVector<int> entityIds);

protected:
    void contextMenuEvent(QContextMenuEvent* event) override;

private slots:
    void onSelectionChanged();
    void onSceneChanged(int revision, QVector<int> entityIds);
    void onEngineSelectionChanged(QVector<int> entityIds);

private:
    void buildTree(const QJsonArray& roots);
    void buildNode(QStandardItem* parent, const QJsonObject& node);
    QStandardItem* findItemByEntityId(int entityId, QStandardItem* root = nullptr) const;

    EngineClient* engine_;
    QStandardItemModel* model_;
    bool suppressSelectionSync_ = false;
};
