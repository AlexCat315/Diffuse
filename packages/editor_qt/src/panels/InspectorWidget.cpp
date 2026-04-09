#include "InspectorWidget.h"
#include "engine/EngineClient.h"

#include <QCheckBox>
#include <QComboBox>
#include <QDebug>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QSpinBox>
#include <QVBoxLayout>

InspectorWidget::InspectorWidget(EngineClient* engine, QWidget* parent)
    : QScrollArea(parent)
    , engine_(engine)
{
    setWidgetResizable(true);
    setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);

    container_ = new QWidget;
    layout_ = new QVBoxLayout(container_);
    layout_->setAlignment(Qt::AlignTop);
    layout_->setContentsMargins(4, 4, 4, 4);
    layout_->setSpacing(8);
    setWidget(container_);

    auto* emptyLabel = new QLabel(tr("No entity selected"));
    emptyLabel->setAlignment(Qt::AlignCenter);
    emptyLabel->setStyleSheet("color: #6c7086; padding: 40px;");
    layout_->addWidget(emptyLabel);
}

// ── Inspect ──────────────────────────────────────────────────────────────

void InspectorWidget::inspect(QVector<int> entityIds)
{
    clear();

    if (entityIds.isEmpty()) return;

    // Inspect first selected entity
    currentEntityId_ = entityIds.first();

    engine_->call("entity.getComponents", {{"entityId", currentEntityId_}},
        [this](const QJsonValue& result, const QString& error) {
            if (!error.isEmpty()) {
                qWarning() << "[Inspector] getComponents failed:" << error;
                return;
            }

            auto components = result.toObject().value("components").toArray();
            for (const auto& comp : components) {
                buildComponentUI(comp.toObject(), currentEntityId_);
            }

            layout_->addStretch();
        });
}

void InspectorWidget::clear()
{
    // Remove all children
    QLayoutItem* item;
    while ((item = layout_->takeAt(0)) != nullptr) {
        if (item->widget()) {
            item->widget()->deleteLater();
        }
        delete item;
    }
    currentEntityId_ = -1;
}

// ── Component UI Builder ─────────────────────────────────────────────────

void InspectorWidget::buildComponentUI(const QJsonObject& component, int entityId)
{
    QString type = component.value("type").toString("Unknown");
    auto fields = component.value("fields").toArray();

    auto* group = new QGroupBox(type);
    auto* form = new QFormLayout(group);
    form->setContentsMargins(8, 16, 8, 8);
    form->setSpacing(4);
    form->setLabelAlignment(Qt::AlignRight | Qt::AlignVCenter);

    for (const auto& fieldVal : fields) {
        auto field = fieldVal.toObject();
        QString name = field.value("name").toString();
        QWidget* editor = createFieldEditor(entityId, type, field);
        if (editor) {
            form->addRow(name, editor);
        }
    }

    layout_->addWidget(group);
}

// ── Field Editor Factory ─────────────────────────────────────────────────

QWidget* InspectorWidget::createFieldEditor(int entityId, const QString& componentType,
                                             const QJsonObject& field)
{
    QString name = field.value("name").toString();
    QString fieldType = field.value("fieldType").toString();
    QJsonValue value = field.value("value");

    auto setField = [this, entityId, componentType, name](const QJsonValue& newValue) {
        engine_->call("entity.setField", {
            {"entityId", entityId},
            {"component", componentType},
            {"field", name},
            {"value", newValue}
        });
    };

    // ── Vec3 (position, rotation, scale) ──
    if (fieldType == "vec3") {
        auto* row = new QWidget;
        auto* hbox = new QHBoxLayout(row);
        hbox->setContentsMargins(0, 0, 0, 0);
        hbox->setSpacing(4);

        QJsonArray arr = value.toArray();
        double x = arr.size() > 0 ? arr[0].toDouble() : 0;
        double y = arr.size() > 1 ? arr[1].toDouble() : 0;
        double z = arr.size() > 2 ? arr[2].toDouble() : 0;

        auto makeSpinBox = [&](double val, const QString& label) -> QDoubleSpinBox* {
            auto* spin = new QDoubleSpinBox;
            spin->setRange(-999999, 999999);
            spin->setDecimals(3);
            spin->setSingleStep(0.1);
            spin->setValue(val);
            spin->setPrefix(label + ": ");
            spin->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
            return spin;
        };

        auto* sx = makeSpinBox(x, "X");
        auto* sy = makeSpinBox(y, "Y");
        auto* sz = makeSpinBox(z, "Z");

        hbox->addWidget(sx);
        hbox->addWidget(sy);
        hbox->addWidget(sz);

        auto emitChange = [sx, sy, sz, setField]() {
            setField(QJsonArray{sx->value(), sy->value(), sz->value()});
        };

        connect(sx, &QDoubleSpinBox::editingFinished, row, emitChange);
        connect(sy, &QDoubleSpinBox::editingFinished, row, emitChange);
        connect(sz, &QDoubleSpinBox::editingFinished, row, emitChange);

        return row;
    }

    // ── Float ──
    if (fieldType == "float" || fieldType == "f32" || fieldType == "f64") {
        auto* spin = new QDoubleSpinBox;
        spin->setRange(-999999, 999999);
        spin->setDecimals(3);
        spin->setSingleStep(0.1);
        spin->setValue(value.toDouble());

        connect(spin, &QDoubleSpinBox::editingFinished, this, [spin, setField]() {
            setField(spin->value());
        });
        return spin;
    }

    // ── Int ──
    if (fieldType == "int" || fieldType == "i32" || fieldType == "u32") {
        auto* spin = new QSpinBox;
        spin->setRange(-999999, 999999);
        spin->setValue(value.toInt());

        connect(spin, &QSpinBox::editingFinished, this, [spin, setField]() {
            setField(spin->value());
        });
        return spin;
    }

    // ── Bool ──
    if (fieldType == "bool") {
        auto* check = new QCheckBox;
        check->setChecked(value.toBool());

        connect(check, &QCheckBox::toggled, this, [setField](bool checked) {
            setField(checked);
        });
        return check;
    }

    // ── String ──
    if (fieldType == "string") {
        auto* edit = new QLineEdit;
        edit->setText(value.toString());

        connect(edit, &QLineEdit::editingFinished, this, [edit, setField]() {
            setField(edit->text());
        });
        return edit;
    }

    // ── Enum (options provided) ──
    if (field.contains("options")) {
        auto* combo = new QComboBox;
        auto options = field.value("options").toArray();
        for (const auto& opt : options) {
            combo->addItem(opt.toString());
        }
        combo->setCurrentText(value.toString());

        connect(combo, &QComboBox::currentTextChanged, this, [setField](const QString& text) {
            setField(text);
        });
        return combo;
    }

    // ── Color (vec4) ──
    if (fieldType == "color" || fieldType == "vec4") {
        auto* row = new QWidget;
        auto* hbox = new QHBoxLayout(row);
        hbox->setContentsMargins(0, 0, 0, 0);
        hbox->setSpacing(4);

        QJsonArray arr = value.toArray();

        auto makeSpinBox = [&](int idx, const QString& label) -> QDoubleSpinBox* {
            auto* spin = new QDoubleSpinBox;
            spin->setRange(0, 1);
            spin->setDecimals(3);
            spin->setSingleStep(0.01);
            spin->setValue(idx < arr.size() ? arr[idx].toDouble() : 0);
            spin->setPrefix(label + ": ");
            spin->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
            return spin;
        };

        auto* sr = makeSpinBox(0, "R");
        auto* sg = makeSpinBox(1, "G");
        auto* sb = makeSpinBox(2, "B");
        auto* sa = makeSpinBox(3, "A");

        hbox->addWidget(sr);
        hbox->addWidget(sg);
        hbox->addWidget(sb);
        hbox->addWidget(sa);

        auto emitChange = [sr, sg, sb, sa, setField]() {
            setField(QJsonArray{sr->value(), sg->value(), sb->value(), sa->value()});
        };

        connect(sr, &QDoubleSpinBox::editingFinished, row, emitChange);
        connect(sg, &QDoubleSpinBox::editingFinished, row, emitChange);
        connect(sb, &QDoubleSpinBox::editingFinished, row, emitChange);
        connect(sa, &QDoubleSpinBox::editingFinished, row, emitChange);

        return row;
    }

    // ── Fallback: read-only label ──
    auto* label = new QLabel(value.toVariant().toString());
    label->setStyleSheet("color: #6c7086;");
    return label;
}
