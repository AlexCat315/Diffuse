import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    color: "#111827"
    border.color: "#1f2937"
    border.width: 1

    required property string statusText
    required property bool leftPanelVisible
    required property bool rightPanelVisible
    required property bool bottomPanelVisible

    signal toggleLeftPanel()
    signal toggleRightPanel()
    signal toggleBottomPanel()

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

        ToolButton {
            text: "Scene"
            checkable: true
            checked: root.leftPanelVisible
            onClicked: root.toggleLeftPanel()
        }

        ToolButton {
            text: "Inspector"
            checkable: true
            checked: root.rightPanelVisible
            onClicked: root.toggleRightPanel()
        }

        ToolButton {
            text: "Bottom"
            checkable: true
            checked: root.bottomPanelVisible
            onClicked: root.toggleBottomPanel()
        }

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
