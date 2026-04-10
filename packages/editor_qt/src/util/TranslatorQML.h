#pragma once

#include <QObject>
#include <QString>
#include "Translator.h"

/**
 *  TranslatorQML — QML-friendly wrapper for Translator
 *
 * Exposes Translator static API as QObject methods callable from QML.
 * Used in main_qml.cpp to pass to QML context.
 */

class TranslatorQML : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString currentLanguage READ currentLanguage WRITE setLanguageProperty)

public:
    explicit TranslatorQML(QObject* parent = nullptr);

    // QML-callable methods
    Q_INVOKABLE QString menu_newScene() const { return Translator::menus().newScene(); }
    Q_INVOKABLE QString menu_openScene() const { return Translator::menus().openScene(); }
    Q_INVOKABLE QString menu_saveScene() const { return Translator::menus().saveScene(); }
    Q_INVOKABLE QString menu_quit() const { return Translator::menus().quit(); }
    
    Q_INVOKABLE QString menu_undo() const { return Translator::menus().undo(); }
    Q_INVOKABLE QString menu_redo() const { return Translator::menus().redo(); }
    
    Q_INVOKABLE QString menu_toggleViewport() const { return Translator::menus().toggleViewport(); }
    Q_INVOKABLE QString menu_toggleHierarchy() const { return Translator::menus().toggleHierarchy(); }
    Q_INVOKABLE QString menu_toggleInspector() const { return Translator::menus().toggleInspector(); }
    
    Q_INVOKABLE QString menu_about() const { return Translator::menus().about(); }
    
    Q_INVOKABLE QString toolbar_translate() const { return Translator::toolbar().translate(); }
    Q_INVOKABLE QString toolbar_rotate() const { return Translator::toolbar().rotate(); }
    Q_INVOKABLE QString toolbar_scale() const { return Translator::toolbar().scale(); }
    Q_INVOKABLE QString toolbar_play() const { return Translator::toolbar().play(); }
    Q_INVOKABLE QString toolbar_pause() const { return Translator::toolbar().pause(); }
    Q_INVOKABLE QString toolbar_stop() const { return Translator::toolbar().stop(); }
    
    Q_INVOKABLE QString dock_viewport() const { return Translator::docks().viewport(); }
    Q_INVOKABLE QString dock_sceneHierarchy() const { return Translator::docks().sceneHierarchy(); }
    Q_INVOKABLE QString dock_inspector() const { return Translator::docks().inspector(); }
    Q_INVOKABLE QString dock_console() const { return Translator::docks().console(); }
    Q_INVOKABLE QString dock_assetBrowser() const { return Translator::docks().assetBrowser(); }
    
    Q_INVOKABLE QString error_failedToConnectEngine() const { return Translator::errors().failedToConnectEngine(); }
    Q_INVOKABLE QString error_engineCrashed() const { return Translator::errors().engineCrashed(); }
    Q_INVOKABLE QString error_failedToSaveScene() const { return Translator::errors().failedToSaveScene(); }
    Q_INVOKABLE QString error_failedToLoadScene() const { return Translator::errors().failedToLoadScene(); }
    
    Q_INVOKABLE QString statusBar_connected() const { return Translator::statusBar().connected(); }
    Q_INVOKABLE QString statusBar_disconnected() const { return Translator::statusBar().disconnected(); }
    
    Q_INVOKABLE QString contextMenu_createEntity() const { return Translator::contextMenu().createEntity(); }
    Q_INVOKABLE QString contextMenu_deleteEntity() const { return Translator::contextMenu().deleteEntity(); }
    Q_INVOKABLE QString contextMenu_duplicateEntity() const { return Translator::contextMenu().duplicateEntity(); }
    Q_INVOKABLE QString contextMenu_renameEntity() const { return Translator::contextMenu().renameEntity(); }
    Q_INVOKABLE QString contextMenu_addComponent() const { return Translator::contextMenu().addComponent(); }
    Q_INVOKABLE QString contextMenu_removeComponent() const { return Translator::contextMenu().removeComponent(); }

    QString currentLanguage() const { return Translator::currentLanguage(); }
    void setLanguageProperty(const QString& lang) { Translator::setLanguage(lang); }
};
