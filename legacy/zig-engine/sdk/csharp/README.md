# Guava C# SDK

通过 .NET 8 NativeAOT 编写 Guava 引擎游戏脚本。

## 目录结构

```
GuavaEngine/           ← SDK 核心库（引用即可）
  GuavaEngine.cs       ← Host API 绑定 + Engine 全局上下文
  GuavaCanvas.cs       ← 运行时 UI Canvas 封装
  GuavaMath.cs         ← Vector2/3, Quaternion, KeyCode
  GuavaScript.cs       ← 脚本基类（OnInit/OnUpdate/OnDestroy）
  ScriptExports.cs     ← NativeAOT 导出桩模板
examples/
  HelloWorld/          ← 示例项目
```

## 快速开始

### 1. 创建项目

```bash
mkdir MyScript && cd MyScript
dotnet new classlib -n MyScript
```

在 `.csproj` 中添加 NativeAOT 属性：

```xml
<PropertyGroup>
    <PublishAot>true</PublishAot>
    <NativeLib>Shared</NativeLib>
    <SelfContained>true</SelfContained>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
</PropertyGroup>

<ItemGroup>
    <ProjectReference Include="path/to/GuavaEngine/GuavaEngine.csproj" />
</ItemGroup>
```

### 2. 编写脚本

```csharp
using Guava;

public class MyScript : GuavaScript
{
    uint hpLabel;

    public override void OnInit()
    {
        hpLabel = Canvas.AddText(10, 10, 200, 24, "HP: 100", Color32.Green);
    }

    public override void OnUpdate(float dt)
    {
        var pos = Transform.GetPosition();
        if (Input.IsKeyDown(KeyCode.W))
            Transform.SetPosition(pos + Vector3.Forward * dt * 5f);
    }
}
```

### 3. 创建 ScriptExports.cs

复制 `GuavaEngine/ScriptExports.cs`，修改 `CreateScript()` 返回你的脚本类。

### 4. 编译

```bash
dotnet publish -c Release -r osx-arm64   # macOS Apple Silicon
dotnet publish -c Release -r osx-x64     # macOS Intel
dotnet publish -c Release -r linux-x64   # Linux
dotnet publish -c Release -r win-x64     # Windows
```

输出的 `.dylib` / `.so` / `.dll` 文件放入项目 `assets/scripts/` 目录，
在编辑器中挂载到实体即可运行。

## 可用 API

| 模块 | 功能 |
|------|------|
| `Log` | `Info(string)` |
| `Transform` | `GetPosition()`, `SetPosition()`, `GetRotation()`, `SetRotation()`, `GetScale()`, `SetScale()` |
| `Input` | `IsKeyDown(KeyCode)`, `WasKeyPressed(KeyCode)`, `GetMousePosition()` |
| `Time` | `DeltaTime`, `TimeScale`, `GameState` |
| `Entity` | `FindByName(string)` |
| `Canvas` | `Clear()`, `AddText()`, `AddPanel()`, `AddButton()`, `AddProgressBar()`, `SetText()`, `SetProgress()`, `SetVisible()`, `RemoveWidget()`, `WasButtonClicked()` |
