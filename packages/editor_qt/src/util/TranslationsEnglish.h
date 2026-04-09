/// English (en_US) translations for Guava Editor Qt
/// 
/// File structure:
/// - Menu items (File, Edit, View, Help)
/// - Toolbar text
/// - Dock titles
/// - Tooltips (Gizmo, Actions)
/// - Error messages
/// - Status bar text
/// - Context menu items

#pragma once

#include <QString>
#include <QMap>

inline static const QMap<QString, QString> TRANSLATIONS_EN_US = {
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
};
