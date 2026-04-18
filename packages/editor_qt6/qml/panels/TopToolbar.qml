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

    function svgUri(svg) {
        return "data:image/svg+xml;utf8," + encodeURIComponent(svg)
    }

    readonly property string iconPlay: svgUri("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><path fill='#cfe1ff' d='M4 2l9 6-9 6z'/></svg>")
    readonly property string iconPause: svgUri("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><rect x='3' y='2' width='4' height='12' fill='#cfe1ff'/><rect x='9' y='2' width='4' height='12' fill='#cfe1ff'/></svg>")
    readonly property string iconStop: svgUri("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><rect x='3' y='3' width='10' height='10' fill='#cfe1ff'/></svg>")
    readonly property string iconDock: svgUri("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><rect x='1' y='2' width='14' height='12' fill='none' stroke='#cfe1ff' stroke-width='1.5'/><line x1='6' y1='2' x2='6' y2='14' stroke='#cfe1ff' stroke-width='1.5'/><line x1='10' y1='2' x2='10' y2='14' stroke='#cfe1ff' stroke-width='1.5'/></svg>")
    readonly property string iconPopout: svgUri("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><path d='M3 5v8h8' fill='none' stroke='#cfe1ff' stroke-width='1.5'/><path d='M7 3h6v6' fill='none' stroke='#cfe1ff' stroke-width='1.5'/><path d='M7 9l6-6' fill='none' stroke='#cfe1ff' stroke-width='1.5'/></svg>")

    component DarkToolButton: ToolButton {
        id: control
        checkable: false
        property string iconSource: ""
        property bool showText: true

        background: Rectangle {
            radius: 3
            color: control.checked ? "#2b3758" : (control.down ? "#232a45" : "#1b2138")
            border.color: control.checked ? "#6ea0ff" : "#353e5e"
            border.width: 1
        }

        contentItem: Label {
            text: ""
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter

            Row {
                anchors.centerIn: parent
                spacing: control.showText ? 6 : 0

                Image {
                    width: control.iconSource.length > 0 ? 13 : 0
                    height: width
                    source: control.iconSource
                    visible: control.iconSource.length > 0
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                }

                Label {
                    visible: control.showText
                    text: control.text
                    color: control.checked ? "#cfe1ff" : "#9da8c9"
                    font.pixelSize: 12
                    font.bold: control.checked
                }
            }
        }

        implicitHeight: 26
        implicitWidth: showText ? Math.max(72, 30 + contentItem.implicitWidth) : 30
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

        DarkToolButton { iconSource: root.iconPlay; showText: false; text: "Play" }
        DarkToolButton { iconSource: root.iconPause; showText: false; text: "Pause" }
        DarkToolButton { iconSource: root.iconStop; showText: false; text: "Stop" }

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
            iconSource: root.iconDock
            onClicked: root.toggleDockConfigurator()
        }

        DarkToolButton {
            text: "Popout"
            iconSource: root.iconPopout
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
