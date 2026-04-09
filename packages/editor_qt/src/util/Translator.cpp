#include "Translator.h"

// ─────────────────────────────────────────────────────────────────────────
// Static Storage & Initialization
// ─────────────────────────────────────────────────────────────────────────

// Note: currentLanguage_ is defined as inline static in Translator.h (C++17+)
// No redefinition needed here

// Inline translations map (can be extended to load from .json files)
static const QMap<QString, QMap<QString, QString>> TRANSLATIONS = {
    // English translations
    {"en_US", {
        // Menu - File
        {"menu.file.newScene", "New Scene"},
        {"menu.file.openScene", "Open Scene..."},
        {"menu.file.saveScene", "Save Scene"},
        {"menu.file.quit", "Quit"},
        
        // Menu - Edit
        {"menu.edit.undo", "Undo"},
        {"menu.edit.redo", "Redo"},
        
        // Menu - View
        {"menu.view.toggleViewport", "Viewport"},
        {"menu.view.toggleHierarchy", "Scene Hierarchy"},
        {"menu.view.toggleInspector", "Inspector"},
        
        // Menu - Help
        {"menu.help.about", "About"},
        
        // Toolbar
        {"toolbar.translate", "Translate (W)"},
        {"toolbar.rotate", "Rotate (E)"},
        {"toolbar.scale", "Scale (R)"},
        {"toolbar.play", "Play"},
        {"toolbar.pause", "Pause"},
        {"toolbar.stop", "Stop"},
        
        // Dock titles
        {"dock.viewport", "Viewport"},
        {"dock.sceneHierarchy", "Scene Hierarchy"},
        {"dock.inspector", "Inspector"},
        {"dock.console", "Console"},
        {"dock.assetBrowser", "Asset Browser"},
        
        // Tooltips - Gizmo
        {"tooltip.gizmo.translate", "Translate (W)"},
        {"tooltip.gizmo.rotate", "Rotate (E)"},
        {"tooltip.gizmo.scale", "Scale (R)"},
        
        // Tooltips - Actions
        {"tooltip.action.save", "Save Scene (Ctrl+S)"},
        {"tooltip.action.undo", "Undo (Ctrl+Z)"},
        {"tooltip.action.redo", "Redo (Ctrl+Y)"},
        {"tooltip.action.refresh", "Refresh Scene"},
        {"tooltip.action.delete", "Delete Entity (Del)"},
        
        // Errors
        {"error.failedToConnect", "Failed to connect to Guava Engine"},
        {"error.engineCrashed", "Guava Engine process crashed"},
        {"error.failedToSave", "Failed to save scene"},
        {"error.failedToLoad", "Failed to load scene"},
        
        // Status bar
        {"status.connected", "Engine connected"},
        {"status.disconnected", "Engine disconnected"},
        {"status.fps", "FPS: %1"},
        
        // Context menu
        {"context.createEntity", "Create Entity"},
        {"context.deleteEntity", "Delete Entity"},
        {"context.duplicateEntity", "Duplicate"},
        {"context.renameEntity", "Rename"},
        {"context.addComponent", "Add Component"},
        {"context.removeComponent", "Remove Component"},
    }},
    
    // Chinese (Simplified) translations
    {"zh_CN", {
        // Menu - File
        {"menu.file.newScene", "新建场景"},
        {"menu.file.openScene", "打开场景..."},
        {"menu.file.saveScene", "保存场景"},
        {"menu.file.quit", "退出"},
        
        // Menu - Edit
        {"menu.edit.undo", "撤销"},
        {"menu.edit.redo", "重做"},
        
        // Menu - View
        {"menu.view.toggleViewport", "视口"},
        {"menu.view.toggleHierarchy", "场景层级"},
        {"menu.view.toggleInspector", "检视器"},
        
        // Menu - Help
        {"menu.help.about", "关于"},
        
        // Toolbar
        {"toolbar.translate", "移动 (W)"},
        {"toolbar.rotate", "旋转 (E)"},
        {"toolbar.scale", "缩放 (R)"},
        {"toolbar.play", "播放"},
        {"toolbar.pause", "暂停"},
        {"toolbar.stop", "停止"},
        
        // Dock titles
        {"dock.viewport", "视口"},
        {"dock.sceneHierarchy", "场景层级"},
        {"dock.inspector", "检视器"},
        {"dock.console", "控制台"},
        {"dock.assetBrowser", "资源浏览器"},
        
        // Tooltips - Gizmo
        {"tooltip.gizmo.translate", "移动 (W)"},
        {"tooltip.gizmo.rotate", "旋转 (E)"},
        {"tooltip.gizmo.scale", "缩放 (R)"},
        
        // Tooltips - Actions
        {"tooltip.action.save", "保存场景 (Ctrl+S)"},
        {"tooltip.action.undo", "撤销 (Ctrl+Z)"},
        {"tooltip.action.redo", "重做 (Ctrl+Y)"},
        {"tooltip.action.refresh", "刷新场景"},
        {"tooltip.action.delete", "删除实体 (Del)"},
        
        // Errors
        {"error.failedToConnect", "无法连接到 Guava 引擎"},
        {"error.engineCrashed", "Guava 引擎进程崩溃"},
        {"error.failedToSave", "保存场景失败"},
        {"error.failedToLoad", "加载场景失败"},
        
        // Status bar
        {"status.connected", "引擎已连接"},
        {"status.disconnected", "引擎未连接"},
        {"status.fps", "帧率: %1"},
        
        // Context menu
        {"context.createEntity", "创建实体"},
        {"context.deleteEntity", "删除实体"},
        {"context.duplicateEntity", "复制"},
        {"context.renameEntity", "重命名"},
        {"context.addComponent", "添加组件"},
        {"context.removeComponent", "移除组件"},
    }},
};

// ─────────────────────────────────────────────────────────────────────────
// Helper
// ─────────────────────────────────────────────────────────────────────────

QString Translator::translate(const QString& context, const QString& key)
{
    auto langIt = TRANSLATIONS.find(currentLanguage_);
    if (langIt == TRANSLATIONS.end()) {
        // Fallback to English if language not found
        langIt = TRANSLATIONS.find("en_US");
    }
    
    auto textIt = langIt->find(key);
    if (textIt != langIt->end()) {
        return *textIt;
    }
    
    // Return key as fallback if translation missing
    return key;
}

// ─────────────────────────────────────────────────────────────────────────
// MenuItems
// ─────────────────────────────────────────────────────────────────────────

QString Translator::MenuItems::newScene() const {
    return Translator::translate("menu", "menu.file.newScene");
}

QString Translator::MenuItems::openScene() const {
    return Translator::translate("menu", "menu.file.openScene");
}

QString Translator::MenuItems::saveScene() const {
    return Translator::translate("menu", "menu.file.saveScene");
}

QString Translator::MenuItems::quit() const {
    return Translator::translate("menu", "menu.file.quit");
}

QString Translator::MenuItems::undo() const {
    return Translator::translate("menu", "menu.edit.undo");
}

QString Translator::MenuItems::redo() const {
    return Translator::translate("menu", "menu.edit.redo");
}

QString Translator::MenuItems::toggleViewport() const {
    return Translator::translate("menu", "menu.view.toggleViewport");
}

QString Translator::MenuItems::toggleHierarchy() const {
    return Translator::translate("menu", "menu.view.toggleHierarchy");
}

QString Translator::MenuItems::toggleInspector() const {
    return Translator::translate("menu", "menu.view.toggleInspector");
}

QString Translator::MenuItems::about() const {
    return Translator::translate("menu", "menu.help.about");
}

// ─────────────────────────────────────────────────────────────────────────
// ToolbarText
// ─────────────────────────────────────────────────────────────────────────

QString Translator::ToolbarText::translate() const {
    return Translator::translate("toolbar", "toolbar.translate");
}

QString Translator::ToolbarText::rotate() const {
    return Translator::translate("toolbar", "toolbar.rotate");
}

QString Translator::ToolbarText::scale() const {
    return Translator::translate("toolbar", "toolbar.scale");
}

QString Translator::ToolbarText::play() const {
    return Translator::translate("toolbar", "toolbar.play");
}

QString Translator::ToolbarText::pause() const {
    return Translator::translate("toolbar", "toolbar.pause");
}

QString Translator::ToolbarText::stop() const {
    return Translator::translate("toolbar", "toolbar.stop");
}

// ─────────────────────────────────────────────────────────────────────────
// DockTitles
// ─────────────────────────────────────────────────────────────────────────

QString Translator::DockTitles::viewport() const {
    return Translator::translate("dock", "dock.viewport");
}

QString Translator::DockTitles::sceneHierarchy() const {
    return Translator::translate("dock", "dock.sceneHierarchy");
}

QString Translator::DockTitles::inspector() const {
    return Translator::translate("dock", "dock.inspector");
}

QString Translator::DockTitles::console() const {
    return Translator::translate("dock", "dock.console");
}

QString Translator::DockTitles::assetBrowser() const {
    return Translator::translate("dock", "dock.assetBrowser");
}

// ─────────────────────────────────────────────────────────────────────────
// Tooltips
// ─────────────────────────────────────────────────────────────────────────

Translator::Tooltips::GizmoTooltips Translator::Tooltips::gizmo() const {
    return GizmoTooltips();
}

Translator::Tooltips::ActionTooltips Translator::Tooltips::actions() const {
    return ActionTooltips();
}

QString Translator::Tooltips::GizmoTooltips::translate() const {
    return Translator::translate("tooltip", "tooltip.gizmo.translate");
}

QString Translator::Tooltips::GizmoTooltips::rotate() const {
    return Translator::translate("tooltip", "tooltip.gizmo.rotate");
}

QString Translator::Tooltips::GizmoTooltips::scale() const {
    return Translator::translate("tooltip", "tooltip.gizmo.scale");
}

QString Translator::Tooltips::ActionTooltips::save() const {
    return Translator::translate("tooltip", "tooltip.action.save");
}

QString Translator::Tooltips::ActionTooltips::undo() const {
    return Translator::translate("tooltip", "tooltip.action.undo");
}

QString Translator::Tooltips::ActionTooltips::redo() const {
    return Translator::translate("tooltip", "tooltip.action.redo");
}

QString Translator::Tooltips::ActionTooltips::refresh() const {
    return Translator::translate("tooltip", "tooltip.action.refresh");
}

QString Translator::Tooltips::ActionTooltips::delete_() const {
    return Translator::translate("tooltip", "tooltip.action.delete");
}

// ─────────────────────────────────────────────────────────────────────────
// ErrorMessages
// ─────────────────────────────────────────────────────────────────────────

QString Translator::ErrorMessages::failedToConnectEngine() const {
    return Translator::translate("error", "error.failedToConnect");
}

QString Translator::ErrorMessages::engineCrashed() const {
    return Translator::translate("error", "error.engineCrashed");
}

QString Translator::ErrorMessages::failedToSaveScene() const {
    return Translator::translate("error", "error.failedToSave");
}

QString Translator::ErrorMessages::failedToLoadScene() const {
    return Translator::translate("error", "error.failedToLoad");
}

// ─────────────────────────────────────────────────────────────────────────
// StatusBarText
// ─────────────────────────────────────────────────────────────────────────

QString Translator::StatusBarText::connected() const {
    return Translator::translate("status", "status.connected");
}

QString Translator::StatusBarText::disconnected() const {
    return Translator::translate("status", "status.disconnected");
}

QString Translator::StatusBarText::fps(int framerate) const {
    QString template_ = Translator::translate("status", "status.fps");
    return template_.arg(framerate);
}

// ─────────────────────────────────────────────────────────────────────────
// ContextMenuItems
// ─────────────────────────────────────────────────────────────────────────

QString Translator::ContextMenuItems::createEntity() const {
    return Translator::translate("context", "context.createEntity");
}

QString Translator::ContextMenuItems::deleteEntity() const {
    return Translator::translate("context", "context.deleteEntity");
}

QString Translator::ContextMenuItems::duplicateEntity() const {
    return Translator::translate("context", "context.duplicateEntity");
}

QString Translator::ContextMenuItems::renameEntity() const {
    return Translator::translate("context", "context.renameEntity");
}

QString Translator::ContextMenuItems::addComponent() const {
    return Translator::translate("context", "context.addComponent");
}

QString Translator::ContextMenuItems::removeComponent() const {
    return Translator::translate("context", "context.removeComponent");
}

// ─────────────────────────────────────────────────────────────────────────
// Static Accessors
// ─────────────────────────────────────────────────────────────────────────

const Translator::MenuItems& Translator::menus() {
    return menuItems_;
}

const Translator::ToolbarText& Translator::toolbar() {
    return toolbarText_;
}

const Translator::DockTitles& Translator::docks() {
    return dockTitles_;
}

const Translator::Tooltips& Translator::tooltips() {
    return tooltips_;
}

const Translator::ErrorMessages& Translator::errors() {
    return errorMessages_;
}

const Translator::StatusBarText& Translator::statusBar() {
    return statusBarText_;
}

const Translator::ContextMenuItems& Translator::contextMenu() {
    return contextMenuItems_;
}

void Translator::setLanguage(const QString& languageCode) {
    currentLanguage_ = languageCode;
}

QString Translator::currentLanguage() {
    return currentLanguage_;
}
