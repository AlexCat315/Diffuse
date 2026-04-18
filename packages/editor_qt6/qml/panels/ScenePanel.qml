import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    color: "#0f172a"
    border.color: "#1e293b"
    border.width: 1

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        Label {
            text: "Scene Hierarchy"
            color: "#e2e8f0"
            font.bold: true
        }

        TextField {
            Layout.fillWidth: true
            placeholderText: "Search actors"
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: ["MainCamera", "DirectionalLight", "Player", "Ground", "PostProcess"]
            delegate: Label {
                width: ListView.view.width
                text: modelData
                color: "#cbd5e1"
                elide: Text.ElideRight
                padding: 4
            }
        }
    }
}
