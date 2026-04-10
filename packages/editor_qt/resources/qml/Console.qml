import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/**
 * Console.qml — Engine output and debug console
 *
 * Displays engine log messages with filtering and search capabilities.
 */

Rectangle {
    id: console
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
                    text: qsTr("Console")
                    color: "#cdd6f4"
                    font.bold: true
                }

                Item { Layout.fillWidth: true }

                Button {
                    text: "🗑"  // Clear
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                }
            }
        }

        // Output view
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            TextEdit {
                readOnly: true
                text: "Engine Console\n\n(Console implementation pending)\n\nEngine output and debug logs\nwill appear here"
                color: "#a6adc8"
                selectByMouse: true
                padding: 8
                wrapMode: TextEdit.Wrap
            }
        }
    }
}
