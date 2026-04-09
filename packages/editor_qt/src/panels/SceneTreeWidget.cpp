#include "SceneTreeWidget.h"
#include "engine/EngineClient.h"

#include <QContextMenuEvent>
#include <QHeaderView>
#include <QInputDialog>
#include <QItemSelectionModel>
#include <QJsonArray>
#include <QJsonObject>
#include <QMenu>
#include <QDebug>

static const int EntityIdRole = Qt::UserRole + 1;

SceneTreeWidget::SceneTreeWidget(EngineClient* engine, QWidget* parent)
    : QTreeView(parent)
    , engine_(engine)
    , model_(new QStandardItemModel(this))
{
    setModel(model_);
    setHeaderHidden(true);
    setExpandsOnDoubleClick(true);
    setDragEnabled(true);
    setAcceptDrops(true);
    setDropIndicatorShown(true);
    setDragDropMode(QAbstractItemView::InternalMove);
    setSelectionMode(QAbstractItemView::ExtendedSelection);
    setEditTriggers(QAbstractItemView::DoubleClicked | QAbstractItemView::EditKeyPressed);

    // Wire selection changes
    connect(selectionModel(), &QItemSelectionModel::selectionChanged,
            this, &SceneTreeWidget::onSelectionChanged);

    // Wire engine events
    connect(engine_, &EngineClient::sceneChanged,
            this, &SceneTreeWidget::onSceneChanged);
    connect(engine_, &EngineClient::selectionChanged,
            this, &SceneTreeWidget::onEngineSelectionChanged);

    // Rename via model edit
    connect(model_, &QStandardItemModel::itemChanged, this, [this](QStandardItem* item) {
        int eid = item->data(EntityIdRole).toInt();
        if (eid <= 0) return;
        engine_->call("entity.setName", {
            {"entityId", eid},
            {"name", item->text()}
        });
    });

    // Auto-refresh when engine connects
    connect(engine_, &EngineClient::connected, this, &SceneTreeWidget::refresh);

    if (engine_->isConnected()) {
        refresh();
    }
}

// ── Data Fetch ───────────────────────────────────────────────────────────

void SceneTreeWidget::refresh()
{
    engine_->call("scene.getHierarchy", {}, [this](const QJsonValue& result, const QString& error) {
        if (!error.isEmpty()) {
            qWarning() << "[SceneTree] getHierarchy failed:" << error;
            return;
        }
        auto roots = result.toObject().value("roots").toArray();
        buildTree(roots);
    });
}

void SceneTreeWidget::buildTree(const QJsonArray& roots)
{
    // Save expanded state
    QSet<int> expandedIds;
    std::function<void(QStandardItem*)> saveExpanded = [&](QStandardItem* item) {
        for (int i = 0; i < item->rowCount(); ++i) {
            auto* child = item->child(i);
            int eid = child->data(EntityIdRole).toInt();
            if (isExpanded(model_->indexFromItem(child)))
                expandedIds.insert(eid);
            saveExpanded(child);
        }
    };
    saveExpanded(model_->invisibleRootItem());

    // Save selection
    QSet<int> selectedIds;
    for (auto& idx : selectionModel()->selectedIndexes()) {
        selectedIds.insert(idx.data(EntityIdRole).toInt());
    }

    model_->clear();

    for (const auto& val : roots) {
        buildNode(model_->invisibleRootItem(), val.toObject());
    }

    // Restore expanded state
    std::function<void(QStandardItem*)> restoreExpanded = [&](QStandardItem* item) {
        for (int i = 0; i < item->rowCount(); ++i) {
            auto* child = item->child(i);
            int eid = child->data(EntityIdRole).toInt();
            if (expandedIds.contains(eid))
                expand(model_->indexFromItem(child));
            restoreExpanded(child);
        }
    };
    restoreExpanded(model_->invisibleRootItem());

    // Restore selection
    suppressSelectionSync_ = true;
    for (int eid : selectedIds) {
        if (auto* item = findItemByEntityId(eid)) {
            selectionModel()->select(model_->indexFromItem(item), QItemSelectionModel::Select);
        }
    }
    suppressSelectionSync_ = false;
}

void SceneTreeWidget::buildNode(QStandardItem* parent, const QJsonObject& node)
{
    int id = node.value("id").toInt();
    QString name = node.value("name").toString(QStringLiteral("Entity %1").arg(id));

    auto* item = new QStandardItem(name);
    item->setData(id, EntityIdRole);
    item->setEditable(true);
    parent->appendRow(item);

    auto children = node.value("children").toArray();
    for (const auto& child : children) {
        buildNode(item, child.toObject());
    }
}

QStandardItem* SceneTreeWidget::findItemByEntityId(int entityId, QStandardItem* root) const
{
    if (!root) root = model_->invisibleRootItem();

    for (int i = 0; i < root->rowCount(); ++i) {
        auto* child = root->child(i);
        if (child->data(EntityIdRole).toInt() == entityId)
            return child;
        if (auto* found = findItemByEntityId(entityId, child))
            return found;
    }
    return nullptr;
}

// ── Selection Sync ───────────────────────────────────────────────────────

void SceneTreeWidget::onSelectionChanged()
{
    if (suppressSelectionSync_) return;

    QVector<int> ids;
    for (auto& idx : selectionModel()->selectedIndexes()) {
        int eid = idx.data(EntityIdRole).toInt();
        if (eid > 0) ids.append(eid);
    }

    engine_->call("editor.setSelection", {{"entityIds", QJsonArray::fromVariantList(
        [&]() -> QVariantList { QVariantList l; for (int id : ids) l << id; return l; }()
    )}});

    emit selectionSynced(ids);
}

void SceneTreeWidget::onEngineSelectionChanged(QVector<int> entityIds)
{
    suppressSelectionSync_ = true;
    selectionModel()->clearSelection();

    for (int eid : entityIds) {
        if (auto* item = findItemByEntityId(eid)) {
            selectionModel()->select(model_->indexFromItem(item),
                QItemSelectionModel::Select | QItemSelectionModel::Rows);
            scrollTo(model_->indexFromItem(item));
        }
    }
    suppressSelectionSync_ = false;

    emit selectionSynced(entityIds);
}

// ── Scene Change ─────────────────────────────────────────────────────────

void SceneTreeWidget::onSceneChanged(int /*revision*/, QVector<int> /*entityIds*/)
{
    // For now, full refresh. Optimize later with incremental updates.
    refresh();
}

// ── Context Menu ─────────────────────────────────────────────────────────

void SceneTreeWidget::contextMenuEvent(QContextMenuEvent* event)
{
    QMenu menu(this);
    auto idx = indexAt(event->pos());
    int parentId = -1;

    if (idx.isValid()) {
        parentId = idx.data(EntityIdRole).toInt();

        menu.addAction(tr("Create Child Entity"), [this, parentId]() {
            engine_->call("scene.createEntity", {
                {"name", "New Entity"},
                {"parentId", parentId}
            });
        });

        menu.addAction(tr("Rename"), [this, idx]() {
            edit(idx);
        });

        menu.addSeparator();

        menu.addAction(tr("Delete"), [this, parentId]() {
            engine_->call("scene.deleteEntity", {{"entityId", parentId}});
        });
    } else {
        menu.addAction(tr("Create Entity"), [this]() {
            engine_->call("scene.createEntity", {{"name", "New Entity"}});
        });
    }

    menu.exec(event->globalPos());
}
