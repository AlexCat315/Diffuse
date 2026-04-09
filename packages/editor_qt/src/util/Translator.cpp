#include "Translator.h"
#include "TranslationsEnglish.h"
#include "TranslationsChinese.h"

// ─────────────────────────────────────────────────────────────────────────
// Static Storage & Initialization
// ─────────────────────────────────────────────────────────────────────────

// Note: currentLanguage_ is defined as inline static in Translator.h (C++17+)
// No redefinition needed here

// ─────────────────────────────────────────────────────────────────────────
// Helper
// ─────────────────────────────────────────────────────────────────────────

QString Translator::translate(const QString& context, const QString& key)
{
    const QMap<QString, QString>* translations = nullptr;
    
    // Select translation map based on current language
    if (currentLanguage_ == "zh_CN") {
        translations = &TRANSLATIONS_ZH_CN;
    } else {
        // Default to English for unknown languages
        translations = &TRANSLATIONS_EN_US;
    }
    
    // Look up translation
    auto textIt = translations->find(key);
    if (textIt != translations->end()) {
        return *textIt;
    }
    
    // Fallback to English if translation not found
    if (currentLanguage_ != "en_US") {
        auto enIt = TRANSLATIONS_EN_US.find(key);
        if (enIt != TRANSLATIONS_EN_US.end()) {
            return *enIt;
        }
    }
    
    // Return key as last resort fallback
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
