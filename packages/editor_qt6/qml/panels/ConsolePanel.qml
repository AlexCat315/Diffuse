import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    color: "#131831"
    border.color: "#2a2f4a"
    border.width: 1

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Label {
                text: "CONSOLE"
                color: "#aeb8d8"
                font.bold: true
                font.pixelSize: 13
                font.letterSpacing: 1.2
            }

            ComboBox {
                model: ["All", "Info", "Warn", "Error"]
                Layout.preferredWidth: 120
            }

            Item { Layout.fillWidth: true }

            Button { text: "Clear" }
        }

        TextArea {
            Layout.fillWidth: true
            Layout.fillHeight: true
            readOnly: true
            wrapMode: TextArea.NoWrap
            color: "#d7e1ff"
            background: Rectangle {
                color: "#10152a"
                border.color: "#2b3353"
                border.width: 1
                radius: 3
            }
            text: "[Info] Editor shell initialized\n[Info] Waiting for runtime logs..."
        }
    }
}
