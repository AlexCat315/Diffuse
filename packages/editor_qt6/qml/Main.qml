import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: root
    width: 1280
    height: 800
    visible: true
    title: "Guava Editor (Qt6 QML)"

    Rectangle {
        id: viewport
        anchors.fill: parent
        color: "#111827"

        Timer {
            id: renderTick
            interval: 0
            repeat: true
            running: true
            onTriggered: {
                marker.x = (marker.x + 5) % Math.max(viewport.width, 1)
                appBackend.frameRendered()
            }
        }

        Repeater {
            model: Math.ceil(viewport.width / 24)
            Rectangle {
                width: 1
                height: viewport.height
                x: index * 24
                y: 0
                color: "#334155"
                opacity: 0.5
            }
        }

        Repeater {
            model: Math.ceil(viewport.height / 24)
            Rectangle {
                width: viewport.width
                height: 1
                x: 0
                y: index * 24
                color: "#334155"
                opacity: 0.5
            }
        }

        Rectangle {
            id: marker
            width: 140
            height: 24
            y: viewport.height / 2 - height / 2
            radius: 12
            color: "#be0ea5e9"
        }

        Rectangle {
            id: overlay
            width: 220
            height: 76
            radius: 8
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 16
            anchors.rightMargin: 16
            color: "#aa38bdf8"
            border.color: "#d2bae6fd"
            border.width: 1
            z: 99

            Column {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 2

                Text {
                    text: "Viewport Overlay"
                    color: "#f8fafc"
                    font.bold: true
                }
                Text {
                    text: "FPS: " + appBackend.fps.toFixed(1)
                    color: "#e2e8f0"
                }
                Text {
                    text: appBackend.statusText
                    color: "#cbd5e1"
                    elide: Text.ElideRight
                }
            }
        }

        Rectangle {
            id: leftPanel
            width: 220
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            color: "#0f172a"
            opacity: 0.9
            z: 10

            Label {
                text: "Scene"
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.leftMargin: 12
                anchors.topMargin: 10
                color: "#e2e8f0"
                font.bold: true
            }
        }

        Rectangle {
            id: rightPanel
            width: 260
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            color: "#0f172a"
            opacity: 0.9
            z: 10

            Label {
                text: "Inspector"
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.leftMargin: 12
                anchors.topMargin: 10
                color: "#e2e8f0"
                font.bold: true
            }
        }

        Rectangle {
            id: bottomPanel
            height: 180
            anchors.left: leftPanel.right
            anchors.right: rightPanel.left
            anchors.bottom: parent.bottom
            color: "#0b1220"
            opacity: 0.92
            z: 12

            Label {
                text: "Console"
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.leftMargin: 12
                anchors.topMargin: 10
                color: "#e2e8f0"
                font.bold: true
            }
        }
    }
}
