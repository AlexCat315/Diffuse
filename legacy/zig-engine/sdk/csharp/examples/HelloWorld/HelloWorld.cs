// ---------------------------------------------------------------------------
// HelloWorld.cs — 示例脚本：HUD + 移动
// ---------------------------------------------------------------------------

using Guava;

public class HelloWorld : GuavaScript
{
    private uint _titleLabel;
    private uint _hpBar;
    private float _hp = 1.0f;

    public override void OnInit()
    {
        Log.Info("HelloWorld script initialized!");

        // 创建 HUD
        Canvas.AddPanel(8, 8, 220, 60, new Color32(20, 20, 40, 200));
        _titleLabel = Canvas.AddText(16, 12, 200, 20, "Hello Guava!", Color32.White);
        _hpBar = Canvas.AddProgressBar(16, 38, 200, 16, _hp);
    }

    public override void OnUpdate(float dt)
    {
        // WASD 移动
        var pos = Transform.GetPosition();
        float speed = 5.0f * dt;

        if (Input.IsKeyDown(KeyCode.W)) pos += Vector3.Forward * speed;
        if (Input.IsKeyDown(KeyCode.S)) pos -= Vector3.Forward * speed;
        if (Input.IsKeyDown(KeyCode.A)) pos -= Vector3.Right * speed;
        if (Input.IsKeyDown(KeyCode.D)) pos += Vector3.Right * speed;

        Transform.SetPosition(pos);

        // 模拟 HP 下降
        _hp -= 0.05f * dt;
        if (_hp < 0) _hp = 1.0f;
        Canvas.SetProgress(_hpBar, _hp);
    }

    public override void OnDestroy()
    {
        Canvas.Clear();
        Log.Info("HelloWorld script destroyed.");
    }
}
