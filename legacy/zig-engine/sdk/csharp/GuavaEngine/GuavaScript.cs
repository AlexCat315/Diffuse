// ---------------------------------------------------------------------------
// GuavaScript.cs — 游戏脚本基类
//
// 继承此类并实现 OnInit/OnUpdate/OnDestroy 即可。
// 引擎通过 NativeAOT 导出的 guava_on_init / guava_on_update / guava_on_destroy
// 调用这些方法。
// ---------------------------------------------------------------------------

namespace Guava
{
    /// <summary>
    /// 游戏脚本基类。
    /// 
    /// <code>
    /// public class MyScript : GuavaScript
    /// {
    ///     uint hpLabel;
    ///     
    ///     public override void OnInit()
    ///     {
    ///         Log.Info("MyScript initialized!");
    ///         hpLabel = Canvas.AddText(10, 10, 200, 24, "HP: 100", Color32.Green);
    ///     }
    ///     
    ///     public override void OnUpdate(float dt)
    ///     {
    ///         var pos = Transform.GetPosition();
    ///         if (Input.IsKeyDown(KeyCode.W))
    ///             Transform.SetPosition(pos + Vector3.Forward * dt * 5f);
    ///     }
    ///     
    ///     public override void OnDestroy()
    ///     {
    ///         Canvas.RemoveWidget(hpLabel);
    ///     }
    /// }
    /// </code>
    /// </summary>
    public abstract class GuavaScript
    {
        /// <summary>脚本初始化时调用（仅一次）。</summary>
        public virtual void OnInit() { }

        /// <summary>每帧调用。</summary>
        /// <param name="deltaTime">帧间隔（秒）</param>
        public virtual void OnUpdate(float deltaTime) { }

        /// <summary>脚本/实体销毁时调用。</summary>
        public virtual void OnDestroy() { }
    }
}
