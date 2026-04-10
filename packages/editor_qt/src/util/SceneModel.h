#pragma once

#include <QAbstractItemModel>
#include <QJsonObject>
#include <QJsonArray>
#include "SceneNode.h"

class EngineClient;

/**
 * SceneModel — QAbstractItemModel for scene hierarchy
 *
 * Integrates with EngineClient to provide real-time scene updates.
 * Used by QML TreeView/Repeater for scene browser UI.
 */

class SceneModel : public QAbstractItemModel
{
    Q_OBJECT

public:
    explicit SceneModel(EngineClient* engineClient, QObject* parent = nullptr);
    ~SceneModel() override;

    // QAbstractItemModel interface
    QModelIndex index(int row, int column, const QModelIndex& parent = QModelIndex()) const override;
    QModelIndex parent(const QModelIndex& index) const override;
    int rowCount(const QModelIndex& parent = QModelIndex()) const override;
    int columnCount(const QModelIndex& parent = QModelIndex()) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    Qt::ItemFlags flags(const QModelIndex& index) const override;

    // Scene operations
    Q_INVOKABLE void createEntity(const QString& parentId, const QString& name);
    Q_INVOKABLE void deleteEntity(const QString& entityId);
    Q_INVOKABLE void renameEntity(const QString& entityId, const QString& newName);
    Q_INVOKABLE void selectEntity(const QString& entityId);
    Q_INVOKABLE void refresh();

    // Data access
    SceneNode* getNode(const QString& id) const;
    SceneNode* rootNode() const { return root_; }

public slots:
    void onSceneUpdated(const QJsonObject& sceneData);
    void onEntityAdded(const QJsonObject& entityData);
    void onEntityRemoved(const QString& entityId);
    void onEntityChanged(const QJsonObject& entityData);

signals:
    void entitySelected(const QString& entityId);
    void sceneModified();

private:
    void buildTreeFromJson(const QJsonArray& entities);
    void updateNodeFromJson(const QString& entityId, const QJsonObject& data);
    SceneNode* findNode(SceneNode* root, const QString& id) const;
    QModelIndex nodeToIndex(SceneNode* node) const;

    EngineClient* engineClient_;
    SceneNode* root_;
    QHash<QString, SceneNode*> nodeMap_;  // Quick lookup by ID
};
