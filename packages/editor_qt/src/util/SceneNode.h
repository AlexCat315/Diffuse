#pragma once

#include <QString>
#include <QList>
#include <memory>
#include <QJsonObject>

/**
 * SceneNode — Represents a single entity in the scene hierarchy
 */

class SceneNode : public QObject
{
    Q_OBJECT

public:
    explicit SceneNode(const QString& id = "", const QString& name = "", QObject* parent = nullptr);
    ~SceneNode() override;

    // Getters
    QString id() const { return id_; }
    QString name() const { return name_; }
    bool isSelected() const { return selected_; }
    int childCount() const { return children_.count(); }
    SceneNode* child(int index) const;
    SceneNode* parentNode() const { return parent_; }

    // Child management
    void addChild(SceneNode* child);
    void removeChild(SceneNode* child);
    void clearChildren();

public slots:
    void setName(const QString& name);
    void setSelected(bool selected);
    void updateFromJson(const QJsonObject& data);

signals:
    void nameChanged(const QString& name);
    void selectedChanged(bool selected);
    void childrenChanged();

private:
    QString id_;
    QString name_;
    bool selected_ = false;
    SceneNode* parent_ = nullptr;
    QList<SceneNode*> children_;
};
