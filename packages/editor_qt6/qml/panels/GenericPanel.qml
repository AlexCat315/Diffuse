import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    color: "#0f172a"
    border.color: "#1e293b"
    border.width: 1

    required property string title

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        Label {
            text: root.title
            color: "#e2e8f0"
            font.bold: true
        }

        Label {
            text: "Panel skeleton (not implemented yet)"
            color: "#94a3b8"
        }

        Item { Layout.fillHeight: true }
    }
}
