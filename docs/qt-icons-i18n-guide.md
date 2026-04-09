# SVG 图标和 i18n 系统集成指南

**日期**: 2026-04-09  
**版本**: 1.0  
**状态**: Phase 1 完成 ✅

## 📋 概述

本文档说明如何在 Guava Qt 编辑器中使用 SVG 图标和国际化（i18n）翻译系统。该系统参照 Electron 版本设计，提供：

- ✅ 50+ SVG 图标资源（Qt 资源系统集成）
- ✅ 集中式 Translator 类（支持多语言）
- ✅ 自动系统语言检测（英文 / 中文）
- ✅ 类型安全的菜单和工具提示 API

---

## 🎨 图标系统

### IconProvider 类

位置：`src/util/IconProvider.h/cpp`

**职责**：
- 从 Qt 资源系统加载 SVG 文件
- 提供命名的、按分类组织的图标 API
- 支持动态颜色和大小调整

**30+ 导出的 QIcon 方法**（按分类）：

```cpp
// File & Scene
IconProvider::save()
IconProvider::openFolder()
IconProvider::folder()
IconProvider::document()
IconProvider::packageIcon()

// Undo / Redo
IconProvider::undo()
IconProvider::redo()

// Playback
IconProvider::play()
IconProvider::pause()
IconProvider::stop()
IconProvider::forward()

// Gizmo / Transform
IconProvider::translate()
IconProvider::rotate()
IconProvider::scale()
IconProvider::cursor()
IconProvider::crosshair()

// UI Actions
IconProvider::close()
IconProvider::refresh()
IconProvider::chevronUp()
IconProvider::chevronDown()
IconProvider::chevronRight()
IconProvider::plus()
IconProvider::deleteIcon()
IconProvider::check()

// Asset Types
IconProvider::model()
IconProvider::texture()
IconProvider::shader()
IconProvider::scene()
IconProvider::script()
IconProvider::audio()
IconProvider::material()
IconProvider::animation()

// ... 更多见头文件
```

### 使用示例

```cpp
#include "util/IconProvider.h"

// 在 action 中使用
QAction* saveAction = menu->addAction("Save");
saveAction->setIcon(IconProvider::save());

// 在工具栏中使用
mainToolBar_->addAction(IconProvider::play(), "Play");

// 自定义大小和颜色（通过 QIcon::setPixmap）
QPixmap pixmap = IconProvider::undo().pixmap(QSize(24, 24));
```

### 添加新图标

1. 将 SVG 文件放入 `resources/icons/svg/`
2. 在 `resources/resources.qrc` 中注册：
   ```xml
   <file>icons/svg/my-icon.svg</file>
   ```
3. 在 `IconProvider.h` 中添加方法声明
4. 在 `IconProvider.cpp` 中实现：
   ```cpp
   QIcon IconProvider::myIcon() {
       return QIcon(loadSvg("my-icon.svg"));
   }
   ```

---

## 🌏 国际化系统

### Translator 类

位置：`src/util/Translator.h/cpp`

**职责**：
- 集中管理所有 UI 文本
- 支持多种语言（目前: English, 中文）
- 提供类型安全的翻译 API

**结构**：

```
Translator
  ├─ menus() → MenuItems
  │   ├─ newScene()
  │   ├─ save()
  │   └─ ...
  ├─ toolbar() → ToolbarText
  │   ├─ translate()
  │   ├─ rotate()
  │   └─ ...
  ├─ docks() → DockTitles
  │   ├─ viewport()
  │   ├─ sceneHierarchy()
  │   └─ ...
  ├─ tooltips() → Tooltips
  │   ├─ gizmo() → GizmoTooltips
  │   └─ actions() → ActionTooltips
  ├─ errors() → ErrorMessages
  ├─ statusBar() → StatusBarText
  └─ contextMenu() → ContextMenuItems
```

### 使用示例

```cpp
#include "util/Translator.h"

// 访问菜单文本
const auto& menus = Translator::menus();
QString text = menus.save();  // "Save" 或 "保存"

// 工具栏
const auto& toolbar = Translator::toolbar();
action->setText(toolbar.play());
action->setToolTip(Translator::tooltips().gizmo().translate());

// Dock 标题
Translator::docks().viewport();  // "Viewport" 或 "视口"

// 错误消息
showError(Translator::errors().failedToConnect());

// 状态栏（带格式化）
statusBar->showMessage(Translator::statusBar().fps(60));
```

### 当前支持的语言

| 代码 | 语言 | 文本数量 |
|------|------|---------|
| `en_US` | English | 50+ |
| `zh_CN` | 中文（简体） | 50+ |

### 自动语言检测

`main.cpp` 中自动检测系统语言：

```cpp
QString systemLanguage = QLocale::system().name();
if (systemLanguage.startsWith("zh")) {
    Translator::setLanguage("zh_CN");
} else {
    Translator::setLanguage("en_US");
}
```

### 添加新翻译文本

1. 在 `Translator.h` 中的相应结构体中添加方法
2. 在 `TRANSLATIONS` 映射中添加键值对（两种语言）
3. 在 `Translator.cpp` 中实现方法

示例：添加新的菜单项

```cpp
// Translator.h
struct MenuItems {
    QString newScene() const;
    QString openScene() const;
    QString myNewItem() const;  // ← 新增
};

// Translator.cpp
static const QMap<QString, QMap<QString, QString>> TRANSLATIONS = {
    {"en_US", {
        ...
        {"menu.file.myNewItem", "My New Menu Item"},
        ...
    }},
    {"zh_CN", {
        ...
        {"menu.file.myNewItem", "我的新菜单项"},
        ...
    }},
};

QString Translator::MenuItems::myNewItem() const {
    return Translator::translate("menu", "menu.file.myNewItem");
}
```

---

## 🔄 集成到 MainWindow

### 当前用法

`MainWindow.cpp` 完全使用 Translator 和 IconProvider：

```cpp
void MainWindow::setupMenuBar()
{
    const auto& menus = Translator::menus();
    
    auto* fileMenu = menuBar()->addMenu("&File");
    auto* saveAct = fileMenu->addAction(menus.save(), QKeySequence::Save, ...);
    saveAct->setIcon(IconProvider::save());
    // ...
}

void MainWindow::setupToolBar()
{
    const auto& toolbar = Translator::toolbar();
    const auto& tooltips = Translator::tooltips();
    
    auto* playAct = mainToolBar_->addAction(
        IconProvider::play(), 
        toolbar.play()
    );
    playAct->setToolTip(tooltips.gizmo().translate());
    // ...
}
```

---

## 📦 资源系统

### resources.qrc 结构

```xml
<qresource prefix="/icons">
    <!-- File & Scene Management -->
    <file>icons/svg/save.svg</file>
    <file>icons/svg/folder-f.svg</file>
    <!-- ... ~50+ icons ... -->
</qresource>
```

### 资源加载

Qt 自动编译资源。SVG 通过以下方式访问：

```cpp
QSvgRenderer renderer(":/icons/save.svg");
```

---

## 🚀 Phase 2 及以后的扩展

### AssetBrowser 面板（Phase 2）

需要新增的图标和翻译：

```cpp
// 新图标
IconProvider::modelFile()
IconProvider::textureFile()
IconProvider::shaderFile()

// 新翻译
"dock.assetBrowser"        // Asset Browser
"context.importAsset"      // Import Asset
"context.deleteAsset"      // Delete Asset
"error.failedToImport"     // Import failed
```

### ConsoleWidget（Phase 2）

```cpp
// 新翻译
"dock.console"             // Console
"status.logLevel.error"    // Error
"status.logLevel.warning"  // Warning
"status.logLevel.info"     // Info
```

### MaterialEditor（Phase 2）

```cpp
// 新图标
IconProvider::materialPreview()

// 新翻译
"context.createMaterial"
"tooltip.material.preview"
"error.failedToCompileShader"
```

---

## 📊 代码统计

| 文件 | 行数 | 职责 |
|------|------|------|
| `IconProvider.h` | 116 | API 声明 |
| `IconProvider.cpp` | 285 | 图标实现 |
| `Translator.h` | 130 | i18n 结构体和 API |
| `Translator.cpp` | 411 | 翻译文本和实现 |
| `resources.qrc` | 86 | 资源注册 |
| **总计** | **1028** | |

---

## ✅ 验证清单

- [x] 所有 SVG 文件在 resources.qrc 中注册
- [x] IconProvider 编译通过
- [x] Translator 支持英文和中文
- [x] main.cpp 自动检测系统语言
- [x] MainWindow 使用 IconProvider 和 Translator
- [x] 可执行文件生成成功（475 KB）
- [x] 没有编译警告或错误

---

## 🔗 参考

- **Electron 版本**: `packages/editor/src/renderer/components/Icons.tsx`
- **Qt SVG 文档**: https://doc.qt.io/qt-6/qsvgrenderer.html
- **Qt i18n 最佳实践**: https://doc.qt.io/qt-6/i18n-source-translation.html

---

## 下一步

1. **Phase 2 UI 组件**: 
   - AssetBrowser（资源浏览器）
   - ConsoleWidget（控制台）
   - MaterialEditor（材质编辑器）

2. **扩展翻译**:
   - 日语（ja_JP）
   - 法语（fr_FR）
   - 等等...

3. **性能优化**:
   - SVG 缓存机制
   - 翻译代码热重载
   - 动态语言切换 UI

---

**作者**: AI Assistant  
**最后更新**: 2026-04-09
