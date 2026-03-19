#!/bin/bash
# 重构 assets 目录结构脚本

set -e

echo "=== 开始重构 assets 目录结构 ==="

cd "$(dirname "$0")/.."

# 创建新的目录结构
echo "创建新的目录结构..."
mkdir -p assets/ui/icons/editor/toolbar
mkdir -p assets/ui/icons/editor/hierarchy
mkdir -p assets/ui/icons/editor/viewport
mkdir -p assets/ui/icons/editor/place_actors

# 移动 heroicons 图标到新的位置
echo "移动工具栏图标..."
for icon in cursor-arrow-rays.svg arrows-up-down.svg arrow-path.svg arrows-pointing-out.svg camera.svg cube.svg eye.svg squares-2x2.svg play.svg pause.svg forward.svg cog-6-tooth.svg light-bulb.svg eye-slash.svg lock-closed.svg lock-open.svg; do
    if [ -f "assets/ui/icons/heroicons/24/solid/$icon" ]; then
        cp "assets/ui/icons/heroicons/24/solid/$icon" assets/ui/icons/editor/toolbar/
        echo "  ✓ toolbar/$icon"
    fi
done

# 移动 filled 图标
echo "移动吸附图标..."
for icon in grid-pattern.svg direction-arrows.svg clock.svg arrow-big-up.svg globe.svg; do
    if [ -f "assets/ui/icons/filled/$icon" ]; then
        cp "assets/ui/icons/filled/$icon" assets/ui/icons/editor/toolbar/
        echo "  ✓ toolbar/$icon"
    fi
done

echo ""
echo "=== 重构完成 ==="
echo ""
echo "新的目录结构:"
echo "  assets/ui/icons/editor/"
echo "    ├── toolbar/     (工具栏图标)"
echo "    ├── hierarchy/   (层级面板图标)"
echo "    ├── viewport/    (视口图标)"
echo "    └── place_actors/ (放置Actor图标)"
echo ""
echo "注意: 需要手动更新 src/editor/ui/icons.zig 中的路径引用"
