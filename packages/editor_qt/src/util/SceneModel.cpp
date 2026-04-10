#include "SceneModel.h"
#include "engine/EngineClient.h"
#include <QJsonArray>
#include <QDebug>

SceneModel::SceneModel(EngineClient* engineClient, QObject* parent)
    : QAbstractItemModel(parent), engineClient_(engineClient)
{
    root_ = new SceneNode("root", "Scene", this);
    nodeMap_["root"] = root_;

    // Initial scene load
    refresh();
}

SceneModel::~SceneModel() = default;

QModelIndex SceneModel::index(int row, int column, const QModelIndex& parent) const
{
    if (!hasIndex(row, column, parent)) {
        return {};
    }

    SceneNode* parentNode = parent.isValid() 
        ? static_cast<SceneNode*>(parent.internalPointer()) 
        : root_;

    if (auto* child = parentNode->child(row)) {
        return createIndex(row, column, child);
    }

    return {};
}

QModelIndex SceneModel::parent(const QModelIndex& index) const
{
    if (!index.isValid()) {
        return {};
    }

    auto* childNode = static_cast<SceneNode*>(index.internalPointer());
    SceneNode* parentNode = childNode->parentNode();

    if (!parentNode || parentNode == root_) {
        return {};
    }

    // Find parent's row in its parent
    auto* grandparent = parentNode->parentNode();
    if (!grandparent) return {};

    for (int i = 0; i < grandparent->childCount(); ++i) {
        if (grandparent->child(i) == parentNode) {
            return createIndex(i, 0, parentNode);
        }
    }

    return {};
}

int SceneModel::rowCount(const QModelIndex& parent) const
{
    SceneNode* parentNode = parent.isValid()
        ? static_cast<SceneNode*>(parent.internalPointer())
        : root_;

    return parentNode->childCount();
}

int SceneModel::columnCount(const QModelIndex&) const
{
    return 1;  // Just entity name
}

QVariant SceneModel::data(const QModelIndex& index, int role) const
{
    if (!index.isValid()) {
        return {};
    }

    auto* node = static_cast<SceneNode*>(index.internalPointer());

    switch (role) {
        case Qt::DisplayRole:
        case Qt::EditRole:
            return node->name();
        case Qt::CheckStateRole:
            return node->isSelected() ? Qt::Checked : Qt::Unchecked;
        default:
            return {};
    }
}

Qt::ItemFlags SceneModel::flags(const QModelIndex& index) const
{
    if (!index.isValid()) {
        return Qt::NoItemFlags;
    }

    return Qt::ItemIsEnabled | Qt::ItemIsSelectable | Qt::ItemIsEditable;
}

void SceneModel::createEntity(const QString& parentId, const QString& name)
{
    if (!engineClient_) return;

    engineClient_->call("scene.createEntity", {
        {"parentId", parentId},
        {"name", name}
    });
}

void SceneModel::deleteEntity(const QString& entityId)
{
    if (!engineClient_) return;

    engineClient_->call("scene.deleteEntity", {
        {"entityId", entityId}
    });
}

void SceneModel::renameEntity(const QString& entityId, const QString& newName)
{
    if (!engineClient_) return;

    engineClient_->call("scene.renameEntity", {
        {"entityId", entityId},
        {"name", newName}
    });
}

void SceneModel::selectEntity(const QString& entityId)
{
    auto* node = getNode(entityId);
    if (node) {
        node->setSelected(true);
        emit entitySelected(entityId);
    }
}

void SceneModel::refresh()
{
    if (!engineClient_) return;

    engineClient_->call("scene.getHierarchy", {}, 
        [this](const QJsonValue& result, const QString& error) {
            if (!error.isEmpty()) {
                qWarning() << "Failed to fetch scene hierarchy:" << error;
                return;
            }

            if (result.isArray()) {
                onSceneUpdated(QJsonObject{{"entities", result}});
            }
        });
}

SceneNode* SceneModel::getNode(const QString& id) const
{
    return nodeMap_.value(id, nullptr);
}

void SceneModel::onSceneUpdated(const QJsonObject& sceneData)
{
    beginResetModel();

    // Clear old tree
    root_->clearChildren();
    nodeMap_.clear();
    nodeMap_["root"] = root_;

    // Rebuild from JSON data
    if (sceneData.contains("entities")) {
        buildTreeFromJson(sceneData["entities"].toArray());
    }

    endResetModel();
    emit sceneModified();
}

void SceneModel::onEntityAdded(const QJsonObject& entityData)
{
    // Insert new node into tree
    QString parentId = entityData["parentId"].toString("root");
    auto* parent = getNode(parentId);
    if (!parent) parent = root_;

    auto* newNode = new SceneNode(
        entityData["id"].toString(),
        entityData["name"].toString(),
        parent
    );
    nodeMap_[newNode->id()] = newNode;

    // Notify model of insertion
    int row = parent->childCount();
    QModelIndex parentIndex = nodeToIndex(parent);
    beginInsertRows(parentIndex, row, row);
    parent->addChild(newNode);
    endInsertRows();

    emit sceneModified();
}

void SceneModel::onEntityRemoved(const QString& entityId)
{
    auto* node = getNode(entityId);
    if (!node) return;

    auto* parent = node->parentNode();
    if (!parent) return;

    int row = -1;
    for (int i = 0; i < parent->childCount(); ++i) {
        if (parent->child(i) == node) {
            row = i;
            break;
        }
    }

    if (row >= 0) {
        QModelIndex parentIndex = nodeToIndex(parent);
        beginRemoveRows(parentIndex, row, row);
        parent->removeChild(node);
        nodeMap_.remove(entityId);
        delete node;
        endRemoveRows();
    }

    emit sceneModified();
}

void SceneModel::onEntityChanged(const QJsonObject& entityData)
{
    QString id = entityData["id"].toString();
    updateNodeFromJson(id, entityData);

    auto* node = getNode(id);
    if (node) {
        // Emit dataChanged for this node
        QModelIndex idx = nodeToIndex(node);
        emit dataChanged(idx, idx);
    }

    emit sceneModified();
}

void SceneModel::buildTreeFromJson(const QJsonArray& entities)
{
    // First pass: create all nodes
    for (const auto& entity : entities) {
        QJsonObject obj = entity.toObject();
        auto* node = new SceneNode(
            obj["id"].toString(),
            obj["name"].toString(),
            this
        );
        node->updateFromJson(obj);
        nodeMap_[node->id()] = node;
    }

    // Second pass: establish parent-child relationships
    for (const auto& entity : entities) {
        QJsonObject obj = entity.toObject();
        QString id = obj["id"].toString();
        QString parentId = obj["parentId"].toString("root");

        auto* node = getNode(id);
        auto* parent = getNode(parentId);

        if (node && parent) {
            parent->addChild(node);
        }
    }
}

void SceneModel::updateNodeFromJson(const QString& entityId, const QJsonObject& data)
{
    auto* node = getNode(entityId);
    if (node) {
        node->updateFromJson(data);
    }
}

SceneNode* SceneModel::findNode(SceneNode* root, const QString& id) const
{
    if (!root) return nullptr;

    if (root->id() == id) {
        return root;
    }

    for (int i = 0; i < root->childCount(); ++i) {
        if (auto* found = findNode(root->child(i), id)) {
            return found;
        }
    }

    return nullptr;
}

QModelIndex SceneModel::nodeToIndex(SceneNode* node) const
{
    if (!node || node == root_) {
        return {};
    }

    auto* parent = node->parentNode();
    if (!parent) return {};

    for (int i = 0; i < parent->childCount(); ++i) {
        if (parent->child(i) == node) {
            return createIndex(i, 0, node);
        }
    }

    return {};
}
