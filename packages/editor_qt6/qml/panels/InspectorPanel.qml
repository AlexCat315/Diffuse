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
        spacing: 10

        Label {
            text: "INSPECTOR"
            color: "#aeb8d8"
            font.bold: true
            font.pixelSize: 13
            font.letterSpacing: 1.2
        }

        GroupBox {
            title: "Transform"
            Layout.fillWidth: true
            background: Rectangle {
                color: "#11162b"
                border.color: "#2b3353"
                border.width: 1
                radius: 4
            }

            GridLayout {
                columns: 4
                columnSpacing: 6
                rowSpacing: 6

                Label { text: "Pos"; color: "#cbd5e1" }
                TextField { placeholderText: "X"; color: "#dbe5ff" }
                TextField { placeholderText: "Y"; color: "#dbe5ff" }
                TextField { placeholderText: "Z"; color: "#dbe5ff" }

                Label { text: "Rot"; color: "#cbd5e1" }
                TextField { placeholderText: "X"; color: "#dbe5ff" }
                TextField { placeholderText: "Y"; color: "#dbe5ff" }
                TextField { placeholderText: "Z"; color: "#dbe5ff" }

                Label { text: "Scale"; color: "#cbd5e1" }
                TextField { placeholderText: "X"; color: "#dbe5ff" }
                TextField { placeholderText: "Y"; color: "#dbe5ff" }
                TextField { placeholderText: "Z"; color: "#dbe5ff" }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
