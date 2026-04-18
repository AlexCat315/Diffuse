import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    color: "#0b1220"
    border.color: "#1e293b"
    border.width: 1

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Label {
                text: "Console"
                color: "#e2e8f0"
                font.bold: true
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
            text: "[Info] Editor shell initialized\n[Info] Waiting for runtime logs..."
        }
    }
}
