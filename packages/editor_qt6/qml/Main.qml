import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import GuavaEditor 1.0

ApplicationWindow {
    id: root
    width: 1280
    height: 800
    visible: true
    title: "Guava Editor (Qt6 QML)"

    property real leftPanelSize: 240
    property real rightPanelSize: 300
    property real bottomPanelSize: 240
    property bool leftPanelVisible: true
    property bool rightPanelVisible: true
    property bool bottomPanelVisible: true
    property string leftPanelId: "scene"
    property string rightPanelId: "inspector"
    property string activeBottomTab: "console"
    property var bottomTabs: ["console", "assets"]
    property bool restoringLayout: false
    property string popoutPanelId: ""
    property var panelRegistry: [
        { id: "scene", title: "Scene", zones: ["left", "right"] },
        { id: "inspector", title: "Inspector", zones: ["left", "right"] },
        { id: "rendersettings", title: "Render Settings", zones: ["left", "right"] },
        { id: "console", title: "Console", zones: ["bottom"] },
        { id: "assets", title: "Content Browser", zones: ["bottom"] }
    ]

    readonly property int layoutSchemaVersion: 1

    function defaultDockLayoutModel() {
        return {
            version: layoutSchemaVersion,
            leftPanelSize: 240,
            rightPanelSize: 300,
            bottomPanelSize: 240,
            leftPanelVisible: true,
            rightPanelVisible: true,
            bottomPanelVisible: true,
            leftPanelId: "scene",
            rightPanelId: "inspector",
            activeBottomTab: "console",
            bottomTabs: ["console", "assets"]
        }
    }

    function panelTitle(panelId) {
        for (let i = 0; i < panelRegistry.length; i += 1) {
            if (panelRegistry[i].id === panelId) {
                return panelRegistry[i].title
            }
        }
        return panelId
    }

    function sidePanelOptions() {
        return panelRegistry.filter(function(panel) {
            return panel.zones.indexOf("left") >= 0 || panel.zones.indexOf("right") >= 0
        })
    }

    function bottomPanelOptions() {
        return panelRegistry.filter(function(panel) {
            return panel.zones.indexOf("bottom") >= 0
        })
    }

    function componentForPanel(panelId) {
        if (panelId === "scene") {
            return scenePanelComponent
        }
        if (panelId === "inspector") {
            return inspectorPanelComponent
        }
        if (panelId === "console") {
            return consolePanelComponent
        }
        if (panelId === "assets") {
            return assetsPanelComponent
        }
        if (panelId === "rendersettings") {
            return renderSettingsPanelComponent
        }
        return unknownPanelComponent
    }

    function bottomTabIndex(panelId) {
        const idx = bottomTabs.indexOf(panelId)
        return idx >= 0 ? idx : 0
    }

    function toggleBottomTab(panelId, enabled) {
        const exists = bottomTabs.indexOf(panelId) >= 0
        if (enabled && !exists) {
            bottomTabs = bottomTabs.concat([panelId])
            activeBottomTab = panelId
            bottomPanelVisible = true
            layoutSaveDebounce.restart()
            return
        }

        if (!enabled && exists) {
            bottomTabs = bottomTabs.filter(function(id) { return id !== panelId })
            if (activeBottomTab === panelId) {
                activeBottomTab = bottomTabs.length > 0 ? bottomTabs[0] : "console"
            }
            if (bottomTabs.length === 0) {
                bottomPanelVisible = false
            }
            layoutSaveDebounce.restart()
        }
    }

    function applyDockLayoutModel(model) {
        restoringLayout = true
        leftPanelSize = Number(model.leftPanelSize) > 0 ? Number(model.leftPanelSize) : 240
        rightPanelSize = Number(model.rightPanelSize) > 0 ? Number(model.rightPanelSize) : 300
        bottomPanelSize = Number(model.bottomPanelSize) > 0 ? Number(model.bottomPanelSize) : 240
        leftPanelVisible = model.leftPanelVisible !== false
        rightPanelVisible = model.rightPanelVisible !== false
        bottomPanelVisible = model.bottomPanelVisible !== false
        leftPanelId = typeof model.leftPanelId === "string" ? model.leftPanelId : "scene"
        rightPanelId = typeof model.rightPanelId === "string" ? model.rightPanelId : "inspector"

        const tabs = Array.isArray(model.bottomTabs) && model.bottomTabs.length > 0
            ? model.bottomTabs.filter(function(id) { return id === "console" || id === "assets" })
            : ["console", "assets"]
        bottomTabs = tabs.length > 0 ? tabs : ["console", "assets"]
        activeBottomTab = bottomTabs.indexOf(model.activeBottomTab) >= 0 ? model.activeBottomTab : bottomTabs[0]
        restoringLayout = false
    }

    function saveDockLayoutModel() {
        if (restoringLayout) {
            return
        }

        dockSettings.layoutJson = JSON.stringify({
            version: layoutSchemaVersion,
            leftPanelSize: leftPanelSize,
            rightPanelSize: rightPanelSize,
            bottomPanelSize: bottomPanelSize,
            leftPanelVisible: leftPanelVisible,
            rightPanelVisible: rightPanelVisible,
            bottomPanelVisible: bottomPanelVisible,
            leftPanelId: leftPanelId,
            rightPanelId: rightPanelId,
            activeBottomTab: activeBottomTab,
            bottomTabs: bottomTabs
        })
    }

    function resetDockLayout() {
        applyDockLayoutModel(defaultDockLayoutModel())
        saveDockLayoutModel()
    }

    function popoutActiveBottomPanel() {
        if (popoutPanelId.length > 0 || !bottomPanelVisible || bottomTabs.length === 0) {
            return
        }

        const panelId = activeBottomTab
        if (bottomTabs.indexOf(panelId) < 0) {
            return
        }

        popoutPanelId = panelId
        bottomTabs = bottomTabs.filter(function(id) { return id !== panelId })

        if (bottomTabs.length === 0) {
            bottomPanelVisible = false
            activeBottomTab = "console"
        } else {
            activeBottomTab = bottomTabs[0]
        }

        popoutWindow.show()
        layoutSaveDebounce.restart()
    }

    function returnPopoutPanel(panelId) {
        if (!panelId || panelId.length === 0) {
            popoutPanelId = ""
            return
        }

        if (bottomTabs.indexOf(panelId) < 0) {
            bottomTabs = bottomTabs.concat([panelId])
        }

        bottomPanelVisible = true
        activeBottomTab = panelId
        popoutPanelId = ""
        layoutSaveDebounce.restart()
    }

    Timer {
        id: layoutSaveDebounce
        interval: 120
        repeat: false
        onTriggered: saveDockLayoutModel()
    }

    Settings {
        id: dockSettings
        category: "DockLayout"
        property string layoutJson: ""
    }

    Component.onCompleted: {
        if (!dockSettings.layoutJson || dockSettings.layoutJson.length === 0) {
            applyDockLayoutModel(defaultDockLayoutModel())
            saveDockLayoutModel()
            return
        }

        try {
            const parsed = JSON.parse(dockSettings.layoutJson)
            if (!parsed || Number(parsed.version) !== layoutSchemaVersion) {
                applyDockLayoutModel(defaultDockLayoutModel())
                saveDockLayoutModel()
                return
            }
            applyDockLayoutModel(parsed)
        } catch (error) {
            applyDockLayoutModel(defaultDockLayoutModel())
            saveDockLayoutModel()
        }
    }

    Rectangle {
        id: viewport
        anchors.fill: parent
        color: "#111827"

        TopToolbar {
            id: topToolbar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 48
            z: 40
            statusText: appBackend.statusText
            leftPanelVisible: root.leftPanelVisible
            rightPanelVisible: root.rightPanelVisible
            bottomPanelVisible: root.bottomPanelVisible
            onToggleLeftPanel: root.leftPanelVisible = !root.leftPanelVisible
            onToggleRightPanel: root.rightPanelVisible = !root.rightPanelVisible
            onToggleBottomPanel: root.bottomPanelVisible = !root.bottomPanelVisible
            onResetLayout: root.resetDockLayout()
            onPopoutBottomPanel: root.popoutActiveBottomPanel()
        }

        Rectangle {
            id: panelConfigurator
            anchors.top: topToolbar.bottom
            anchors.right: parent.right
            anchors.topMargin: 8
            anchors.rightMargin: 8
            width: 300
            height: 120
            color: "#111827"
            border.color: "#334155"
            border.width: 1
            radius: 6
            z: 50

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Label {
                        text: "Left"
                        color: "#cbd5e1"
                        Layout.preferredWidth: 36
                    }

                    ComboBox {
                        Layout.fillWidth: true
                        model: root.sidePanelOptions()
                        textRole: "title"
                        valueRole: "id"
                        currentIndex: Math.max(0, indexOfValue(root.leftPanelId))
                        onActivated: function(index) {
                            if (index >= 0 && index < model.length) {
                                root.leftPanelId = model[index].id
                            }
                            layoutSaveDebounce.restart()
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Label {
                        text: "Right"
                        color: "#cbd5e1"
                        Layout.preferredWidth: 36
                    }

                    ComboBox {
                        Layout.fillWidth: true
                        model: root.sidePanelOptions()
                        textRole: "title"
                        valueRole: "id"
                        currentIndex: Math.max(0, indexOfValue(root.rightPanelId))
                        onActivated: function(index) {
                            if (index >= 0 && index < model.length) {
                                root.rightPanelId = model[index].id
                            }
                            layoutSaveDebounce.restart()
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        text: "Bottom"
                        color: "#cbd5e1"
                    }

                    Repeater {
                        model: root.bottomPanelOptions()

                        CheckBox {
                            required property var modelData
                            text: modelData.title
                            checked: root.bottomTabs.indexOf(modelData.id) >= 0
                            onToggled: root.toggleBottomTab(modelData.id, checked)
                        }
                    }
                }
            }
        }

        PanelPopoutWindow {
            id: popoutWindow
            panelId: root.popoutPanelId
            visible: false
            onReturnPanel: function(panelId) {
                root.returnPopoutPanel(panelId)
            }
        }

        SplitView {
            id: horizontalDock
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: topToolbar.bottom
            anchors.bottom: parent.bottom
            orientation: Qt.Horizontal

            Loader {
                id: leftPanel
                visible: root.leftPanelVisible
                SplitView.preferredWidth: root.leftPanelSize
                SplitView.minimumWidth: root.leftPanelVisible ? 200 : 0
                sourceComponent: root.componentForPanel(root.leftPanelId)
                onWidthChanged: if (visible && width > 0) {
                    root.leftPanelSize = width
                    layoutSaveDebounce.restart()
                }
            }

            SplitView {
                id: centerDock
                orientation: Qt.Vertical
                SplitView.fillWidth: true
                SplitView.fillHeight: true

                Item {
                    id: viewportCenter
                    SplitView.fillWidth: true
                    SplitView.fillHeight: true

                    Image {
                        id: engineFrame
                        anchors.fill: parent
                        source: appBackend.frameDataUrl
                        fillMode: Image.PreserveAspectCrop
                        smooth: false
                        cache: false
                        asynchronous: true
                        visible: !zeroCopyViewport.active && source !== ""
                    }

                    ZeroCopyViewport {
                        id: zeroCopyViewport
                        anchors.fill: parent
                        z: 1

                        Component.onCompleted: {
                            appBackend.updateViewportRect(0, 0, width, height)
                            setSurfaceHandle(appBackend.surfaceId, appBackend.surfaceWidth, appBackend.surfaceHeight)
                        }

                        onWidthChanged: appBackend.updateViewportRect(0, 0, width, height)
                        onHeightChanged: appBackend.updateViewportRect(0, 0, width, height)
                    }

                    Connections {
                        target: appBackend

                        function onZeroCopyReadyChanged() {
                            zeroCopyViewport.setSurfaceHandle(appBackend.surfaceId, appBackend.surfaceWidth, appBackend.surfaceHeight)
                        }
                    }

                    Timer {
                        id: renderTick
                        interval: 0
                        repeat: true
                        running: true
                        onTriggered: {
                            marker.x = (marker.x + 5) % Math.max(viewportCenter.width, 1)
                            appBackend.frameRendered()
                        }
                    }

                    Timer {
                        id: overlayPulse
                        interval: 120
                        repeat: true
                        running: true
                        onTriggered: appBackend.reportOverlayPulse()
                    }

                    Repeater {
                        model: Math.ceil(viewportCenter.width / 24)
                        Rectangle {
                            width: 1
                            height: viewportCenter.height
                            x: index * 24
                            y: 0
                            color: "#334155"
                            opacity: (engineFrame.visible || zeroCopyViewport.active) ? 0.08 : 0.5
                        }
                    }

                    Repeater {
                        model: Math.ceil(viewportCenter.height / 24)
                        Rectangle {
                            width: viewportCenter.width
                            height: 1
                            x: 0
                            y: index * 24
                            color: "#334155"
                            opacity: (engineFrame.visible || zeroCopyViewport.active) ? 0.08 : 0.5
                        }
                    }

                    Rectangle {
                        id: marker
                        width: 140
                        height: 24
                        y: viewportCenter.height / 2 - height / 2
                        radius: 12
                        color: "#be0ea5e9"
                        opacity: (engineFrame.visible || zeroCopyViewport.active) ? 0.25 : 1.0
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

                    ViewportInputLayer {
                        appBackend: appBackend
                        anchors.fill: parent
                        z: 20
                    }
                }

                Item {
                    id: bottomDock
                    visible: root.bottomPanelVisible
                    SplitView.preferredHeight: root.bottomPanelSize
                    SplitView.minimumHeight: root.bottomPanelVisible ? 180 : 0
                    onHeightChanged: if (visible && height > 0) {
                        root.bottomPanelSize = height
                        layoutSaveDebounce.restart()
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        TabBar {
                            id: bottomTabBar
                            Layout.fillWidth: true

                            Repeater {
                                model: root.bottomTabs

                                TabButton {
                                    required property string modelData
                                    text: root.panelTitle(modelData)
                                    checked: root.activeBottomTab === modelData
                                    onClicked: {
                                        root.activeBottomTab = modelData
                                        layoutSaveDebounce.restart()
                                    }
                                }
                            }
                        }

                        StackLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            currentIndex: root.bottomTabIndex(root.activeBottomTab)

                            Repeater {
                                model: root.bottomTabs

                                Loader {
                                    required property string modelData
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    sourceComponent: root.componentForPanel(modelData)
                                }
                            }
                        }
                    }
                }
            }

            Loader {
                id: rightPanel
                visible: root.rightPanelVisible
                SplitView.preferredWidth: root.rightPanelSize
                SplitView.minimumWidth: root.rightPanelVisible ? 240 : 0
                sourceComponent: root.componentForPanel(root.rightPanelId)
                onWidthChanged: if (visible && width > 0) {
                    root.rightPanelSize = width
                    layoutSaveDebounce.restart()
                }
            }
        }
    }

    onLeftPanelVisibleChanged: layoutSaveDebounce.restart()
    onRightPanelVisibleChanged: layoutSaveDebounce.restart()
    onBottomPanelVisibleChanged: layoutSaveDebounce.restart()
    onLeftPanelIdChanged: layoutSaveDebounce.restart()
    onRightPanelIdChanged: layoutSaveDebounce.restart()

    Component {
        id: scenePanelComponent
        ScenePanel { }
    }

    Component {
        id: inspectorPanelComponent
        InspectorPanel { }
    }

    Component {
        id: consolePanelComponent
        ConsolePanel { }
    }

    Component {
        id: assetsPanelComponent
        ContentBrowserPanel { }
    }

    Component {
        id: renderSettingsPanelComponent
        GenericPanel {
            title: "Render Settings"
        }
    }

    Component {
        id: unknownPanelComponent
        GenericPanel {
            title: "Unknown Panel"
        }
    }
}
