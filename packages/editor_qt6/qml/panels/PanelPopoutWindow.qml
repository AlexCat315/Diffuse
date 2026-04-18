import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Window {
    id: root
    width: 860
    height: 560
    visible: true
    title: panelTitle

    required property string panelId
    required property string panelTitle
    required property var panelComponent
    required property string originZone
    required property int originIndex

    signal returnPanel(string panelId, string originZone, int originIndex)

    onClosing: function(close) {
        root.returnPanel(root.panelId, root.originZone, root.originIndex)
    }

    Loader {
        anchors.fill: parent
        sourceComponent: root.panelComponent ? root.panelComponent : fallbackComponent
    }

    Component {
        id: fallbackComponent
        GenericPanel {
            anchors.fill: parent
            title: root.panelTitle
        }
    }
}
