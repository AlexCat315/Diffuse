import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    color: "#111427"
    border.color: "#2a2f4a"
    border.width: 1

    required property string statusText
    required property bool leftPanelVisible
    required property bool rightPanelVisible
    required property bool bottomPanelVisible
    required property bool dockConfiguratorVisible

    signal toggleLeftPanel()
    signal toggleRightPanel()
    signal toggleBottomPanel()
    signal toggleDockConfigurator()
    signal resetLayout()
    signal popoutBottomPanel()
    signal popoutLeftPanel()
    signal popoutRightPanel()

    component DarkToolButton: ToolButton {
        id: control
        checkable: false

        background: Rectangle {
            radius: 3
            color: control.checked ? "#2b3758" : (control.down ? "#232a45" : "#1b2138")
            border.color: control.checked ? "#6ea0ff" : "#353e5e"
            border.width: 1
        }

        contentItem: Label {
            text: control.text
            color: control.checked ? "#cfe1ff" : "#9da8c9"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: 12
            font.bold: control.checked
        }

        implicitHeight: 26
        implicitWidth: Math.max(72, contentItem.implicitWidth + 20)
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        anchors.topMargin: 6
        anchors.bottomMargin: 6
        spacing: 6

        Label {
            text: "Guava"
            color: "#dce6ff"
            font.bold: true
            font.pixelSize: 17
            Layout.rightMargin: 8
        }

        DarkToolButton { text: "Play" }
        DarkToolButton { text: "Pause" }
        DarkToolButton { text: "Stop" }

        Rectangle {
            Layout.preferredWidth: 1
            Layout.fillHeight: true
            color: "#2a2f4a"
            opacity: 0.85
            Layout.leftMargin: 4
            Layout.rightMargin: 4
        }

        DarkToolButton {
            text: "Scene"
            checkable: true
            checked: root.leftPanelVisible
            onClicked: root.toggleLeftPanel()
        }

        DarkToolButton {
            text: "Inspector"
            checkable: true
            checked: root.rightPanelVisible
            onClicked: root.toggleRightPanel()
        }

        DarkToolButton {
            text: "Bottom"
            checkable: true
            checked: root.bottomPanelVisible
            onClicked: root.toggleBottomPanel()
        }

        DarkToolButton {
            text: root.dockConfiguratorVisible ? "Hide Dock" : "Show Dock"
            checkable: true
            checked: root.dockConfiguratorVisible
            onClicked: root.toggleDockConfigurator()
        }

        DarkToolButton {
            text: "Popout"
            onClicked: root.popoutBottomPanel()
        }

        Item { Layout.fillWidth: true }

        Label {
            text: root.statusText
            color: "#7ca1e8"
            elide: Text.ElideRight
            Layout.preferredWidth: 380
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: 12
        }
    }
}
