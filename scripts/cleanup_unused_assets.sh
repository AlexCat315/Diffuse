#!/bin/bash
# 清理未使用的图标资源脚本

set -e

echo "=== 开始清理未使用的图标资源 ==="

# 进入项目根目录
cd "$(dirname "$0")/.."

# 创建备份目录
BACKUP_DIR="assets_backup_$(date +%Y%m%d_%H%M%S)"
echo "创建备份目录: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# 备份并删除 outline 目录（全部未使用）
if [ -d "assets/ui/icons/outline" ]; then
    echo "备份并删除 assets/ui/icons/outline/ ..."
    cp -r assets/ui/icons/outline "$BACKUP_DIR/"
    rm -rf assets/ui/icons/outline
    echo "  ✓ 已删除 outline 目录"
fi

# 备份并删除 svg 目录（全部未使用）
if [ -d "assets/ui/icons/svg" ]; then
    echo "备份并删除 assets/ui/icons/svg/ ..."
    cp -r assets/ui/icons/svg "$BACKUP_DIR/"
    rm -rf assets/ui/icons/svg
    echo "  ✓ 已删除 svg 目录"
fi

# 清理 filled 目录，只保留使用的 5 个图标
if [ -d "assets/ui/icons/filled" ]; then
    echo "清理 assets/ui/icons/filled/，只保留使用的图标..."
    cp -r assets/ui/icons/filled "$BACKUP_DIR/"
    
    # 创建临时目录保存需要保留的文件
    mkdir -p assets/ui/icons/filled_temp
    
    # 保留使用的图标
    for icon in grid-pattern.svg direction-arrows.svg clock.svg arrow-big-up.svg globe.svg; do
        if [ -f "assets/ui/icons/filled/$icon" ]; then
            cp "assets/ui/icons/filled/$icon" assets/ui/icons/filled_temp/
            echo "  ✓ 保留: $icon"
        fi
    done
    
    # 替换原目录
    rm -rf assets/ui/icons/filled
    mv assets/ui/icons/filled_temp assets/ui/icons/filled
    echo "  ✓ 已清理 filled 目录"
fi

echo ""
echo "=== 清理完成 ==="
echo "备份位置: $BACKUP_DIR"
echo ""
echo "要永久删除备份，请运行: rm -rf $BACKUP_DIR"
