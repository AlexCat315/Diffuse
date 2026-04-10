import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/**
 * Assets.qml — Asset browser with thumbnail grid and drag-drop support
 *
 * Explores project assets, displays thumbnails, and supports
 * drag-drop into scene for entity creation.
 */

Rectangle {
    id: assets
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
                    text: qsTr("Assets")
                    color: "#cdd6f4"
                    font.bold: true
                }

                Item { Layout.fillWidth: true }

                TextField {
                    placeholderText: qsTr("Search...")
                    Layout.preferredWidth: 150
                }
            }
        }

        // Asset grid (placeholder)
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            TextEdit {
                readOnly: true
                text: "Asset Browser\n\n(Asset grid implementation pending)\n\nDrag assets from here\ninto the Viewport to create entities"
                color: "#a6adc8"
                selectByMouse: false
                padding: 8
                wrapMode: TextEdit.Wrap
            }
        }
    }
}
