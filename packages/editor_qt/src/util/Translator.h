#pragma once

#include <QString>
#include <QMap>

/**
 * Translator — Centralized i18n management for Guava Editor (Qt).
 *
 * Provides translated strings for:
 * - Menu items and actions
 * - Dialog titles and messages
 * - Tooltips and hints
 * - Error messages
 * - Status bar text
 *
 * Organized by functional categories to mirror the Electron i18n structure.
 *
 * Usage:
 *   QString text = Translator::menu().file().save();
 *   QString tooltip = Translator::tooltip().gizmo().translate();
 *   QString error = Translator::error().failedToConnect();
 */

class Translator
{
public:
    struct MenuItems {
        // File menu
        QString newScene() const;
        QString openScene() const;
        QString saveScene() const;
        QString quit() const;
        
        // Edit menu
        QString undo() const;
        QString redo() const;
        
        // View menu
        QString toggleViewport() const;
        QString toggleHierarchy() const;
        QString toggleInspector() const;
        
        // Help menu
        QString about() const;
    };
    
    struct ToolbarText {
        QString translate() const;
        QString rotate() const;
        QString scale() const;
        QString play() const;
        QString pause() const;
        QString stop() const;
    };
    
    struct DockTitles {
        QString viewport() const;
        QString sceneHierarchy() const;
        QString inspector() const;
        QString console() const;
        QString assetBrowser() const;
    };
    
    struct Tooltips {
        struct GizmoTooltips {
            QString translate() const;
            QString rotate() const;
            QString scale() const;
        };
        
        struct ActionTooltips {
            QString save() const;
            QString undo() const;
            QString redo() const;
            QString refresh() const;
            QString delete_() const;
        };
        
        GizmoTooltips gizmo() const;
        ActionTooltips actions() const;
    };
    
    struct ErrorMessages {
        QString failedToConnectEngine() const;
        QString engineCrashed() const;
        QString failedToSaveScene() const;
        QString failedToLoadScene() const;
    };
    
    struct StatusBarText {
        QString connected() const;
        QString disconnected() const;
        QString fps(int framerate) const;
    };
    
    struct ContextMenuItems {
        QString createEntity() const;
        QString deleteEntity() const;
        QString duplicateEntity() const;
        QString renameEntity() const;
        QString addComponent() const;
        QString removeComponent() const;
    };
    
    // Static access to translation groups
    static const MenuItems& menus();
    static const ToolbarText& toolbar();
    static const DockTitles& docks();
    static const Tooltips& tooltips();
    static const ErrorMessages& errors();
    static const StatusBarText& statusBar();
    static const ContextMenuItems& contextMenu();
    
    // Set current language (e.g., "en_US", "zh_CN", "ja_JP")
    static void setLanguage(const QString& languageCode);
    static QString currentLanguage();

private:
    static QString translate(const QString& context, const QString& key);
    
    // Singleton instances
    inline static MenuItems menuItems_;
    inline static ToolbarText toolbarText_;
    inline static DockTitles dockTitles_;
    inline static Tooltips tooltips_;
    inline static ErrorMessages errorMessages_;
    inline static StatusBarText statusBarText_;
    inline static ContextMenuItems contextMenuItems_;
    inline static QString currentLanguage_ = "en_US";
};
