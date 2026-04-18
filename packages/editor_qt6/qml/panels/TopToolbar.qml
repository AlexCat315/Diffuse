import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    color: "#111827"
    border.color: "#1f2937"
    border.width: 1

    required property string statusText

    RowLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8

        Label {
            text: "Guava"
            color: "#f8fafc"
            font.bold: true
        }

        Button { text: "Play" }
        Button { text: "Pause" }
        Button { text: "Stop" }

        Item { Layout.fillWidth: true }

        Label {
            text: root.statusText
            color: "#93c5fd"
            elide: Text.ElideRight
            Layout.preferredWidth: 360
            horizontalAlignment: Text.AlignRight
        }
    }
}
