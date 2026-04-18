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
        spacing: 10

        Label {
            text: "Inspector"
            color: "#e2e8f0"
            font.bold: true
        }

        GroupBox {
            title: "Transform"
            Layout.fillWidth: true

            GridLayout {
                columns: 4
                columnSpacing: 6
                rowSpacing: 6

                Label { text: "Pos"; color: "#cbd5e1" }
                TextField { placeholderText: "X" }
                TextField { placeholderText: "Y" }
                TextField { placeholderText: "Z" }

                Label { text: "Rot"; color: "#cbd5e1" }
                TextField { placeholderText: "X" }
                TextField { placeholderText: "Y" }
                TextField { placeholderText: "Z" }

                Label { text: "Scale"; color: "#cbd5e1" }
                TextField { placeholderText: "X" }
                TextField { placeholderText: "Y" }
                TextField { placeholderText: "Z" }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
