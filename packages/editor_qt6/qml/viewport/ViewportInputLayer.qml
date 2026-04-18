import QtQuick

Item {
    id: root

    required property var appBackend

    function mapMouseButton(button) {
        if (button === Qt.LeftButton) {
            return 1
        }
        if (button === Qt.RightButton) {
            return 2
        }
        if (button === Qt.MiddleButton) {
            return 3
        }
        return 0
    }

    focus: true

    Keys.onPressed: function(event) {
        appBackend.sendViewportInput(
            "keyDown",
            0,
            0,
            0,
            event.key,
            (event.modifiers & Qt.ShiftModifier) !== 0,
            (event.modifiers & Qt.ControlModifier) !== 0,
            (event.modifiers & Qt.AltModifier) !== 0,
            0,
            0
        )
    }

    Keys.onReleased: function(event) {
        appBackend.sendViewportInput(
            "keyUp",
            0,
            0,
            0,
            event.key,
            (event.modifiers & Qt.ShiftModifier) !== 0,
            (event.modifiers & Qt.ControlModifier) !== 0,
            (event.modifiers & Qt.AltModifier) !== 0,
            0,
            0
        )
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        propagateComposedEvents: true

        onPressed: function(mouse) {
            root.forceActiveFocus()
            appBackend.sendViewportInput(
                "mouseDown",
                mouse.x,
                mouse.y,
                root.mapMouseButton(mouse.button),
                0,
                (mouse.modifiers & Qt.ShiftModifier) !== 0,
                (mouse.modifiers & Qt.ControlModifier) !== 0,
                (mouse.modifiers & Qt.AltModifier) !== 0,
                0,
                0
            )
        }

        onReleased: function(mouse) {
            appBackend.sendViewportInput(
                "mouseUp",
                mouse.x,
                mouse.y,
                root.mapMouseButton(mouse.button),
                0,
                (mouse.modifiers & Qt.ShiftModifier) !== 0,
                (mouse.modifiers & Qt.ControlModifier) !== 0,
                (mouse.modifiers & Qt.AltModifier) !== 0,
                0,
                0
            )
        }

        onPositionChanged: function(mouse) {
            appBackend.sendViewportInput(
                "mouseMove",
                mouse.x,
                mouse.y,
                0,
                0,
                (mouse.modifiers & Qt.ShiftModifier) !== 0,
                (mouse.modifiers & Qt.ControlModifier) !== 0,
                (mouse.modifiers & Qt.AltModifier) !== 0,
                0,
                0
            )
        }

        onWheel: function(wheel) {
            appBackend.sendViewportInput(
                "wheel",
                wheel.x,
                wheel.y,
                0,
                0,
                (wheel.modifiers & Qt.ShiftModifier) !== 0,
                (wheel.modifiers & Qt.ControlModifier) !== 0,
                (wheel.modifiers & Qt.AltModifier) !== 0,
                wheel.angleDelta.x,
                wheel.angleDelta.y
            )
        }
    }
}
