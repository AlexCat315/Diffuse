#pragma once

#include <QScrollArea>
#include <QVBoxLayout>
#include <QJsonArray>
#include <QJsonObject>
#include <QVector>

class EngineClient;
class QFormLayout;
class QLabel;
class QGroupBox;

/// InspectorWidget — Displays and edits components of selected entities.
///
/// Dynamically builds a property editor per component from entity.getComponents.
/// Supports: Transform, MeshRenderer, Light, Camera, Script, and generic fallback.
class InspectorWidget : public QScrollArea
{
    Q_OBJECT

public:
    explicit InspectorWidget(EngineClient* engine, QWidget* parent = nullptr);

    /// Show components for the given entity IDs (only first entity inspected).
    void inspect(QVector<int> entityIds);

    /// Clear the inspector panel.
    void clear();

private:
    void buildComponentUI(const QJsonObject& component, int entityId);
    QWidget* createFieldEditor(int entityId, const QString& componentType,
                               const QJsonObject& field);

    EngineClient* engine_;
    QWidget* container_;
    QVBoxLayout* layout_;
    int currentEntityId_ = -1;
};
