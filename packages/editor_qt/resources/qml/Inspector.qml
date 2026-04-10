import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/**
 * Inspector.qml — Dynamic property editor for selected entities
 *
 * Shows Transform, Components, and custom properties based on
 * the previously selected entity from SceneTree.
 */

Rectangle {
    id: inspector
    color: "#313244"

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 0
        spacing: 0

        // Header toolbar
        ToolBar {
            Layout.fillWidth: true
            Layout.preferredHeight: 32

            RowLayout {
                anchors.fill: parent
                anchors.margins: 4

                Text {
                    text: qsTr("Inspector")
                    color: "#cdd6f4"
                    font.bold: true
                }

                Item { Layout.fillWidth: true }
            }
        }

        // Properties view (placeholder)
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            TextEdit {
                readOnly: true
                text: "Entity Properties\n\n(Inspector implementation pending)\n\nSelect an entity in Scene Tree\nto view its Transform & Components"
                color: "#a6adc8"
                selectByMouse: false
                padding: 8
                wrapMode: TextEdit.Wrap
            }
        }
    }

    // Bindings to display properties of selected entity
    property string selectedEntityId: ""
    property var selectedEntity: ({})

    onSelectedEntityIdChanged: {
        // Fetch entity details
        if (selectedEntityId !== "") {
            EngineClient.call("scene.getEntity", {
                entityId: selectedEntityId
            }, function(result) {
                selectedEntity = result
            })
        }
    }
}
