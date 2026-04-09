/// Chinese Simplified (zh_CN) translations for Guava Editor Qt
///
/// 文件结构：
/// - 菜单项（文件、编辑、查看、帮助）
/// - 工具栏文本
/// - 面板标题
/// - 工具提示（变换、操作）
/// - 错误消息
/// - 状态栏文本
/// - 上下文菜单项

#pragma once

#include <QString>
#include <QMap>

inline static const QMap<QString, QString> TRANSLATIONS_ZH_CN = {
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
};
