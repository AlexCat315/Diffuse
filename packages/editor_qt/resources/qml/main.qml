import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ApplicationWindow {
    id: mainWindow
    width: 1440
    height: 900
    minimumWidth: 1024
    minimumHeight: 720
    visible: true
    title: "Guava Editor"

    color: "#1e1e2e"
    palette.buttonText: "#cdd6f4"
    palette.text: "#cdd6f4"

    // Connect to engine signals
    Connections {
        target: EngineClient
        function onConnected() {
            statusBar.messageLabel.text = qsTr("Engine connected")
        }
        function onDisconnected() {
            statusBar.messageLabel.text = qsTr("Engine disconnected")
        }
        function onFramerateChanged(fps) {
            statusBar.fpsLabel.text = fps + " FPS"
        }
    }

    // ── Menu Bar ──────────────────────────────────────────────────────────
    menuBar: MenuBar {
        Menu {
            title: qsTr("&File")
            
            Action {
                text: qsTr("&New Scene")
                shortcut: StandardKey.New
                onTriggered: {
                    EngineClient.call("scene.createEntity", {name: "New Entity"})
                }
            }
            
            Action {
                text: qsTr("&Open")
                shortcut: StandardKey.Open
                onTriggered: {
                    // TODO: file dialog
                }
            }
            
            Action {
                text: qsTr("&Save")
                shortcut: StandardKey.Save
                onTriggered: {
                    EngineClient.call("scene.save", {})
                }
            }
            
            MenuSeparator {}
            
            Action {
                text: qsTr("&Quit")
                shortcut: StandardKey.Quit
                onTriggered: Qt.quit()
            }
        }
        
        Menu {
            title: qsTr("&Edit")
            
            Action {
                text: qsTr("&Undo")
                shortcut: StandardKey.Undo
                onTriggered: {
                    EngineClient.call("editor.undo", {})
                }
            }
            
            Action {
                text: qsTr("&Redo")
                shortcut: StandardKey.Redo
                onTriggered: {
                    EngineClient.call("editor.redo", {})
                }
            }
        }
        
        Menu {
            title: qsTr("&View")
            
            Action {
                text: qsTr("Toggle &Viewport")
                onTriggered: viewportPanel.visible = !viewportPanel.visible
            }
            
            Action {
                text: qsTr("Toggle &Hierarchy")
                onTriggered: scenePanel.visible = !scenePanel.visible
            }
            
            Action {
                text: qsTr("Toggle &Inspector")
                onTriggered: inspectorPanel.visible = !inspectorPanel.visible
            }
        }
        
        Menu {
            title: qsTr("&Help")
            
            Action {
                text: qsTr("&About")
                onTriggered: {
                    aboutDialog.open()
                }
            }
        }
    }

    // ── Toolbar ───────────────────────────────────────────────────────────
    header: ToolBar {
        RowLayout {
            anchors.fill: parent
            anchors.margins: 4
            spacing: 4
            
            // Gizmo mode buttons
            Button {
                text: "▲"  // Translate gizmo
                checkable: true
                checked: true
                onClicked: {
                    EngineClient.call("viewport.setGizmoMode", {mode: "translate"})
                }
            }
            
            Button {
                text: "⟳"  // Rotate gizmo
                checkable: true
                onClicked: {
                    EngineClient.call("viewport.setGizmoMode", {mode: "rotate"})
                }
            }
            
            Button {
                text: "⬌"  // Scale gizmo
                checkable: true
                onClicked: {
                    EngineClient.call("viewport.setGizmoMode", {mode: "scale"})
                }
            }
            
            ToolSeparator {}
            
            // Playback controls
            Button {
                text: "▶"  // Play
                onClicked: {
                    EngineClient.call("playback.play", {})
                }
            }
            
            Button {
                text: "⏸"  // Pause
                onClicked: {
                    EngineClient.call("playback.pause", {})
                }
            }
            
            Button {
                text: "⏹"  // Stop
                onClicked: {
                    EngineClient.call("playback.stop", {})
                }
            }
            
            Item { Layout.fillWidth: true }  // Spacer
        }
    }

    // ── Main Content ──────────────────────────────────────────────────────
    contentData: [
        SplitView {
            anchors.fill: parent
            orientation: Qt.Horizontal
            
            // Left panel: Hierarchy
            Rectangle {
                id: scenePanel
                Layout.minimumWidth: 200
                Layout.preferredWidth: 300
                color: "#313244"
                border.color: "#45475a"
                border.width: 1
                
                SceneTree {
                    anchors.fill: parent
                }
            }
            
            // Center: Viewport
            Rectangle {
                id: viewportPanel
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#1e1e2e"
                
                Viewport {
                    anchors.fill: parent
                }
            }
            
            // Right panel: Inspector
            Rectangle {
                id: inspectorPanel
                Layout.minimumWidth: 200
                Layout.preferredWidth: 300
                color: "#313244"
                border.color: "#45475a"
                border.width: 1
                
                Inspector {
                    anchors.fill: parent
                }
            }
        }
    ]

    // ── Status Bar ────────────────────────────────────────────────────────
    footer: ToolBar {
        id: statusBar
        
        RowLayout {
            anchors.fill: parent
            anchors.margins: 4
            
            Text {
                id: messageLabel
                text: qsTr("Ready")
                color: "#cdd6f4"
            }
            
            Item { Layout.fillWidth: true }
            
            Text {
                id: fpsLabel
                text: "60 FPS"
                color: "#cdd6f4"
                Layout.rightMargin: 16
            }
        }
    }

    // ── About Dialog ──────────────────────────────────────────────────────
    Dialog {
        id: aboutDialog
        title: qsTr("About Guava Editor")
        standardButtons: Dialog.Ok
        
        contentItem: Column {
            spacing: 12
            padding: 16
            
            Text {
                text: "Guava Editor v0.1.0"
                font.pixelSize: 16
                font.bold: true
                color: "#cdd6f4"
            }
            
            Text {
                text: qsTr("Native Qt Edition")
                color: "#a6adc8"
            }
        }
    }
}
