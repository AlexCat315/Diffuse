// ---------------------------------------------------------------------------
// GuavaCanvas.cs — 运行时 UI Canvas 高层封装
// ---------------------------------------------------------------------------

using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Guava
{
    /// <summary>RGBA 颜色（0-255）。</summary>
    public readonly struct Color32
    {
        public readonly byte R, G, B, A;

        public Color32(byte r, byte g, byte b, byte a = 255) { R = r; G = g; B = b; A = a; }

        public static readonly Color32 White = new(255, 255, 255, 255);
        public static readonly Color32 Black = new(0, 0, 0, 255);
        public static readonly Color32 Red = new(255, 0, 0, 255);
        public static readonly Color32 Green = new(0, 255, 0, 255);
        public static readonly Color32 Blue = new(0, 0, 255, 255);
        public static readonly Color32 Yellow = new(255, 255, 0, 255);
        public static readonly Color32 Transparent = new(0, 0, 0, 0);
    }

    /// <summary>
    /// 运行时 UI Canvas — 在游戏脚本中创建/修改 HUD 元素。
    /// 
    /// 示例用法：
    /// <code>
    /// var hp = Canvas.AddText(10, 10, 200, 24, "HP: 100", Color32.Green);
    /// var bar = Canvas.AddProgressBar(10, 40, 200, 16, 0.75f);
    /// Canvas.SetProgress(bar, 0.5f);
    /// Canvas.RemoveWidget(hp);
    /// </code>
    /// </summary>
    public static unsafe class Canvas
    {
        /// <summary>清除画布上所有控件。</summary>
        public static void Clear()
        {
            Engine.Api->CanvasClear(Engine.Context);
        }

        /// <summary>
        /// 添加文本标签。
        /// </summary>
        /// <param name="x">左上角 X 坐标（像素）</param>
        /// <param name="y">左上角 Y 坐标（像素）</param>
        /// <param name="width">宽度（像素）</param>
        /// <param name="fontSize">字号（同时作为行高）</param>
        /// <param name="text">文本内容</param>
        /// <param name="color">文字颜色</param>
        /// <returns>控件 ID（0 = 失败）</returns>
        public static uint AddText(float x, float y, float width, float fontSize, string text, Color32 color)
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            fixed (byte* ptr = bytes)
            {
                return Engine.Api->CanvasAddText(Engine.Context, x, y, width, fontSize,
                    ptr, (nuint)bytes.Length, color.R, color.G, color.B, color.A);
            }
        }

        /// <summary>
        /// 添加带背景色的面板。
        /// </summary>
        /// <returns>控件 ID（0 = 失败）</returns>
        public static uint AddPanel(float x, float y, float width, float height, Color32 background)
        {
            return Engine.Api->CanvasAddPanel(Engine.Context, x, y, width, height,
                background.R, background.G, background.B, background.A);
        }

        /// <summary>
        /// 添加按钮（面板 + 居中文本，可点击）。
        /// </summary>
        /// <returns>控件 ID（0 = 失败）</returns>
        public static uint AddButton(float x, float y, float width, float height, string label)
        {
            var bytes = Encoding.UTF8.GetBytes(label);
            fixed (byte* ptr = bytes)
            {
                return Engine.Api->CanvasAddButton(Engine.Context, x, y, width, height,
                    ptr, (nuint)bytes.Length);
            }
        }

        /// <summary>
        /// 添加进度条。
        /// </summary>
        /// <param name="progress">初始进度 0.0 ~ 1.0</param>
        /// <returns>控件 ID（0 = 失败）</returns>
        public static uint AddProgressBar(float x, float y, float width, float height, float progress)
        {
            return Engine.Api->CanvasAddProgressBar(Engine.Context, x, y, width, height, progress);
        }

        /// <summary>修改文本控件的内容。</summary>
        public static void SetText(uint widgetId, string text)
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            fixed (byte* ptr = bytes)
            {
                Engine.Api->CanvasSetText(Engine.Context, widgetId, ptr, (nuint)bytes.Length);
            }
        }

        /// <summary>修改进度条的进度（0.0 ~ 1.0）。</summary>
        public static void SetProgress(uint widgetId, float progress)
        {
            Engine.Api->CanvasSetProgress(Engine.Context, widgetId, progress);
        }

        /// <summary>设置控件是否可见。</summary>
        public static void SetVisible(uint widgetId, bool visible)
        {
            Engine.Api->CanvasSetVisible(Engine.Context, widgetId, visible ? 1u : 0u);
        }

        /// <summary>移除控件及其子节点。</summary>
        public static void RemoveWidget(uint widgetId)
        {
            Engine.Api->CanvasRemoveWidget(Engine.Context, widgetId);
        }

        /// <summary>按钮是否在当前帧被点击。</summary>
        public static bool WasButtonClicked(uint widgetId)
        {
            return Engine.Api->CanvasWasButtonClicked(Engine.Context, widgetId) != 0;
        }
    }
}
