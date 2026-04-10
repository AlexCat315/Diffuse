#include "SceneNode.h"
#include <QJsonObject>

SceneNode::SceneNode(const QString& id, const QString& name, QObject* parent)
    : QObject(parent), id_(id), name_(name)
{
}

SceneNode::~SceneNode()
{
    clearChildren();
}

SceneNode* SceneNode::child(int index) const
{
    if (index >= 0 && index < children_.count()) {
        return children_[index];
    }
    return nullptr;
}

void SceneNode::addChild(SceneNode* child)
{
    if (!child) return;
    child->parent_ = this;
    children_.append(child);
    emit childrenChanged();
}

void SceneNode::removeChild(SceneNode* child)
{
    if (children_.removeOne(child)) {
        child->parent_ = nullptr;
        emit childrenChanged();
    }
}

void SceneNode::clearChildren()
{
    for (auto* child : children_) {
        delete child;
    }
    children_.clear();
    if (!children_.isEmpty()) {
        emit childrenChanged();
    }
}

void SceneNode::setName(const QString& name)
{
    if (name_ != name) {
        name_ = name;
        emit nameChanged(name);
    }
}

void SceneNode::setSelected(bool selected)
{
    if (selected_ != selected) {
        selected_ = selected;
        emit selectedChanged(selected);
    }
}

void SceneNode::updateFromJson(const QJsonObject& data)
{
    if (data.contains("name")) {
        setName(data["name"].toString());
    }
    if (data.contains("selected")) {
        setSelected(data["selected"].toBool());
    }
}
