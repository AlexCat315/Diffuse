import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Window {
    id: root
    width: 860
    height: 560
    visible: false
    title: panelId === "assets" ? "Content Browser" : "Console"

    required property string panelId

    signal returnPanel(string panelId)

    onClosing: function(close) {
        root.returnPanel(root.panelId)
    }

    Loader {
        anchors.fill: parent
        sourceComponent: root.panelId === "assets" ? assetsComponent : consoleComponent
    }

    Component {
        id: consoleComponent
        ConsolePanel { anchors.fill: parent }
    }

    Component {
        id: assetsComponent
        ContentBrowserPanel { anchors.fill: parent }
    }
}
