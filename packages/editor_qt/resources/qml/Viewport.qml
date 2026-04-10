import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import GuavaEditor 1.0

/**
 * Viewport.qml — Native Metal rendering viewport with input handling
 *
 * Uses C++ MetalViewportItem for direct Metal rendering to IOSurface.
 * Integrated with EngineClient for bidirectional communication.
 */

Rectangle {
    id: viewport
    color: "#000000"

    // Native Metal rendering item
    MetalViewportItem {
        id: metalViewport
        anchors.fill: parent
        
        // Reference to engine client for RPC calls
        engine: EngineClient
        
        Component.onCompleted: {
            console.log("Metal viewport initialized")
        }
        
        onViewportReady: {
            console.log("Viewport ready for rendering")
        }
    }

    // FPS indicator overlay
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: 100
        height: 30
        color: "#00000080"
        radius: 4
        visible: parent.width > 400
        
        Text {
            anchors.centerIn: parent
            text: "FPS: 60"
            color: "#a6adc8"
            font.pixelSize: 12
        }
    }

    // Placeholder while Metal is initializing
    Column {
        anchors.centerIn: parent
        spacing: 8
        visible: metalViewport.width === 0
        
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Initializing Metal viewport..."
            color: "#666666"
            font.pixelSize: 14
        }
        
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Engine must be running with --editor-server flag"
            color: "#555555"
            font.pixelSize: 11
        }
    }
}

