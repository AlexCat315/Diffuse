import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/**
 * SceneTree.qml — Hierarchical scene object browser
 *
 * Displays scene entities using C++ SceneModel via QAbstractItemModel.
 * - Double-click to select
 * - Right-click for context menu
 * - Drag-drop reordering (future)
 */

Rectangle {
    id: sceneTree
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
                spacing: 4

                Text {
                    text: qsTr("Scene")
                    color: "#cdd6f4"
                    font.bold: true
                }

                Item { Layout.fillWidth: true }

                Button {
                    text: "+"
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    onClicked: {
                        // Create new entity
                        if (SceneModel) {
                            SceneModel.createEntity("root", qsTr("New Entity"))
                        }
                    }
                }

                Button {
                    text: "−"
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    onClicked: {
                        // Delete selected entity
                        if (currentSelection !== "" && SceneModel) {
                            SceneModel.deleteEntity(currentSelection)
                        }
                    }
                }
            }
        }

        // Scene tree view
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ColumnLayout {
                width: parent.width
                spacing: 2

                // Scene root item
                Rectangle {
                    Layout.preferredWidth: parent.width - 4
                    Layout.preferredHeight: 24
                    color: currentSelection === "root" ? "#585b70" : "transparent"
                    radius: 2

                    MouseArea {
                        anchors.fill: parent
                        onDoubleClicked: {
                            currentSelection = "root"
                            if (SceneModel) {
                                SceneModel.selectEntity("root")
                            }
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        text: "▼ Scene"
                        color: "#cdd6f4"
                        font.pixelSize: 12
                    }
                }

                // Placeholder entities list
                Text {
                    Layout.preferredWidth: parent.width - 4
                    Layout.preferredHeight: 60
                    text: "Entities\n(Model implementation pending)\n\nDouble-click to select\nRight-click for context menu"
                    color: "#a6adc8"
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    padding: 8
                }

                Item { Layout.fillHeight: true }
            }
        }
    }

    // Current selection state
    property string currentSelection: ""

    // Connect to model signals
    Connections {
        target: SceneModel
        function onSceneModified() {
            console.log("Scene modified")
        }
        function onEntitySelected(entityId) {
            currentSelection = entityId
        }
    }
}

