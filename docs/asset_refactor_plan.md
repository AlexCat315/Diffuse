# Assets 目录重构计划

## 当前问题

### 1. 图标资源冗余严重
- `assets/ui/icons/filled/` - 约 150 个文件，仅使用 5 个
- `assets/ui/icons/outline/` - 约 400 个文件，全部未使用
- `assets/ui/icons/svg/` - 约 200 个文件，全部未使用
- 总计约 **750 个未使用的图标文件**

### 2. 目录结构不清晰
- 图标分散在多个子目录
- 没有按功能分类
- 难以维护

## 重构方案

### Phase 1: 清理未使用资源

#### 步骤 1.1: 运行清理脚本
```bash
chmod +x scripts/cleanup_unused_assets.sh
./scripts/cleanup_unused_assets.sh
```

这将：
1. 备份所有被删除的文件到 `assets_backup_YYYYMMDD_HHMMSS/`
2. 删除 `outline/` 目录（全部未使用）
3. 删除 `svg/` 目录（全部未使用）
4. 清理 `filled/` 目录，只保留 5 个使用的图标

#### 步骤 1.2: 验证清理结果
```bash
# 统计剩余图标数量
find assets/ui/icons -name "*.svg" | wc -l
# 应该只有约 22 个图标
```

### Phase 2: 重构目录结构

#### 步骤 2.1: 运行重构脚本
```bash
chmod +x scripts/reorganize_assets.sh
./scripts/reorganize_assets.sh
```

新的目录结构：
```
assets/ui/icons/
├── editor/                    # 编辑器专用图标
│   ├── toolbar/              # 工具栏图标 (17个)
│   ├── hierarchy/            # 层级面板图标
│   ├── viewport/             # 视口图标
│   └── place_actors/         # 放置Actor图标
└── heroicons/                # 保留原始heroicons
    └── 24/solid/             # 17个使用的图标
```

#### 步骤 2.2: 更新代码引用
需要更新 `src/editor/ui/icons.zig` 中的路径：

**当前路径:**
```zig
pub const select = "assets/ui/icons/heroicons/24/solid/cursor-arrow-rays.svg";
pub const snap = "assets/ui/icons/filled/grid-pattern.svg";
```

**新路径:**
```zig
pub const select = "assets/ui/icons/editor/toolbar/cursor-arrow-rays.svg";
pub const snap = "assets/ui/icons/editor/toolbar/grid-pattern.svg";
```

### Phase 3: 代码层面优化

#### 3.1 更新 icons.zig
```zig
pub const paths = struct {
    pub const toolbar = struct {
        pub const select = "assets/ui/icons/editor/toolbar/cursor-arrow-rays.svg";
        pub const move = "assets/ui/icons/editor/toolbar/arrows-up-down.svg";
        // ... 其他工具栏图标
    };
    
    pub const snap = struct {
        pub const grid = "assets/ui/icons/editor/toolbar/grid-pattern.svg";
        pub const translate = "assets/ui/icons/editor/toolbar/direction-arrows.svg";
        // ... 其他吸附图标
    };
};
```

#### 3.2 添加资源加载错误处理
在 `icon_cache.zig` 中添加：
```zig
pub fn ensureIconTexture(...) !*Texture {
    // 检查文件是否存在
    if (!std.fs.cwd().access(path, .{})) {
        std.log.warn("Icon not found: {s}", .{path});
        return error.IconNotFound;
    }
    // ... 原有逻辑
}
```

### Phase 4: Git 清理

#### 4.1 从 Git 历史中删除大文件
```bash
# 安装 git-filter-repo（如果未安装）
pip install git-filter-repo

# 删除已删除文件的 Git 历史
git filter-repo --path assets/ui/icons/outline --invert-paths
git filter-repo --path assets/ui/icons/svg --invert-paths

# 或者使用 BFG Repo-Cleaner
java -jar bfg.jar --delete-folders outline assets/ui/icons/
java -jar bfg.jar --delete-folders svg assets/ui/icons/
```

**注意:** 这会重写 Git 历史，需要所有协作者重新克隆仓库。

#### 4.2 更新 .gitignore
```gitignore
# 备份目录
assets_backup_*/

# 临时文件
*.tmp
*.bak
```

## 预期效果

### 存储空间节省
- 清理前: ~750 个图标文件，估计 5-10 MB
- 清理后: ~22 个图标文件，估计 <100 KB
- **节省约 95% 的图标存储空间**

### 构建时间
- 减少资源复制时间
- 减少文件系统遍历时间

### 维护性
- 清晰的目录结构
- 易于查找和替换图标
- 减少混淆

## 风险评估

### 低风险
- 清理未使用的图标是安全的
- 有备份脚本，可随时恢复

### 中风险
- 路径更新可能遗漏某些引用
- 需要全面测试编辑器功能

### 高风险
- Git 历史重写会影响所有协作者
- 建议在主要版本发布时进行

## 回滚方案

如果需要回滚：
```bash
# 从备份恢复
mv assets/ui/icons assets/ui/icons_new
cp -r assets_backup_YYYYMMDD_HHMMSS/* assets/ui/icons/

# 恢复代码更改
git checkout src/editor/ui/icons.zig
```

## 检查清单

- [ ] 运行清理脚本
- [ ] 运行重构脚本
- [ ] 更新 icons.zig 路径
- [ ] 测试编辑器所有功能
- [ ] 运行完整测试套件
- [ ] 更新文档
- [ ] 通知团队成员
- [ ] 考虑 Git 历史清理
