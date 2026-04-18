import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    color: "#171b33"
    border.color: "#2a2f4a"
    border.width: 1

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        Label {
            text: "SCENE HIERARCHY"
            color: "#aeb8d8"
            font.bold: true
            font.pixelSize: 13
            font.letterSpacing: 1.2
        }

        TextField {
            Layout.fillWidth: true
            placeholderText: "Search entities..."
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
            model: ["MainCamera", "DirectionalLight", "Player", "Ground", "PostProcess"]
            delegate: Label {
                width: ListView.view.width
                text: modelData
                color: "#d7e1ff"
                elide: Text.ElideRight
                padding: 3
                font.pixelSize: 12
            }
        }
    }
}
