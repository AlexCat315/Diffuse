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

        Label {
            text: "CONTENT BROWSER"
            color: "#aeb8d8"
            font.bold: true
            font.pixelSize: 13
            font.letterSpacing: 1.2
        }

        TextField {
            Layout.fillWidth: true
            placeholderText: "Filter assets"
            color: "#dbe5ff"
            placeholderTextColor: "#6f7ba1"
            background: Rectangle {
                radius: 4
                color: "#11162b"
                border.color: "#2b3353"
                border.width: 1
            }
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: ["materials/", "meshes/", "textures/", "scripts/", "scenes/"]
            delegate: Label {
                width: ListView.view.width
                text: modelData
                color: "#d7e1ff"
                elide: Text.ElideRight
                padding: 4
                font.pixelSize: 12
            }
        }
    }
}
