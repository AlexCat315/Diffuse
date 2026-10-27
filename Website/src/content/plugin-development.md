# 插件开发

Diffuse 编辑器面向 macOS、Windows 和 Linux。插件统一使用 TypeScript，运行于应用随附的固定版本 Bun。Swift/Cove 提供原生窗口、渲染与平台服务。

## 独立开发

插件项目只依赖 `@diffuse/plugin-sdk`，不导入 EditorCore，也不需要检出 Diffuse 源码。SDK 尚未发布到包仓库时，可从 `PluginSDK` 执行 `bun pm pack`，将生成的 tarball 分发给开发者并安装。

最小目录：

```text
my-plugin/
├── plugin.json
└── src/index.ts
```

```json
{
  "id": "example.counter",
  "version": 1,
  "name": "Counter",
  "description": "一个独立插件界面",
  "access": "read",
  "imports": [],
  "composable_host_capabilities": [],
  "contributes": {
    "cove.ui.panel/v1": [{
      "id": "counter",
      "title": "Counter",
      "surface": "counter",
      "entryPoint": "view"
    }]
  }
}
```

```ts
import { capability, definePlugin } from '@diffuse/plugin-sdk';

let count = 0;
export default definePlugin({ capabilities: {
  view: capability({ record: {
    view: 'string', state: 'string', event: 'string', context: 'string'
  } }, ({ event }) => {
    if (event && JSON.parse(event).action === 'increment') count++;
    return { ui: { type: 'column', spacing: 8, children: [
      { type: 'text', text: String(count) },
      { type: 'button', title: 'Increment', action: 'increment' }
    ] } };
  })
} });
```

`surface` 将界面加入窗口的顶层模式切换。省略它时，面板加入工作台布局。两者使用同一套视图协议，第三方无需获得宿主专用视图名称。

## 构建和安装

安装 SDK 后使用其 `diffuse-plugin build SOURCE OUTPUT.coveplugin` 命令。在 Diffuse 仓库中可运行：

```sh
./cove studio plugins prepare
./cove plugin build /path/to/my-plugin --output /path/to/my-plugin.coveplugin
```

生成的包包含 `plugin.json`、`plugin.js`、`capabilities.json` 和已声明的资源。运行时声明由构建工具生成。已有输出目录不会被静默覆盖。通过编辑器的插件设置选择插件包，检查后启用。

安装检查读取静态契约、校验文件和权限声明，并绑定代码、契约与资源摘要。更新后的包需要匹配新的授权。插件不在运行时自动安装 npm 依赖。

## 界面协议

入口收到四个字符串：`view`、`state`、`event` 和 `context`。首次渲染的事件为空。上下文包含当前工作内容、项目目录、窗口项目列表和插件存储目录。

返回值为：

```ts
{
  state: { /* 下次调用交还的视图状态 */ },
  ui: { type: 'column', children: [] },
  effects: [],
  refreshAfterMilliseconds: 500
}
```

可使用布局、滚动、文本、按钮、输入框、选择器、开关、折叠区域与表格。组件的 `key` 保持身份；`flex`、`width`、`fillWidth`、`maxWidth` 控制布局。`fillWidth:true` 填满可用宽度，并受 `maxWidth` 约束。事件携带 `action`、`arguments`、`value` 和当前控件的 `values`。密码输入使用 `secure`，诊断快照不会读取其值。

顶层模式使用 `surface` 注册中央视图；模式内的其他面板使用 `inSurface` 指定完整模式 ID，并通过 `slot` 选择 `leading`、`trailing` 或 `bottom`。例如第三方产物面板可声明 `inSurface:"studio.ai.assistant", slot:"trailing"`。两侧区域支持独立折叠，多插件面板按标签选择；这些贡献不会混入工作台。依赖该模式的插件应在 `requires` 中声明模式所有者。

后台状态可请求后续刷新，间隔限制在 100–10000 毫秒。渲染不应等待整个模型请求或长任务完成。

## 生命周期

`activate(scope)` 初始化插件实例；`scope.own(...)` 登记释放操作，`scope.signal` 表示插件退出。`deactivate()` 可中止任务并保存状态。宿主给予有界清理时间，随后终止执行进程。

所有贡献都归所属插件管理。退出时移除其界面、命令和贡献，旧事件不应继续修改已撤销的会话。

## 执行权限

Bun 插件是可信桌面扩展，拥有其进程的系统权限。manifest 限定 Diffuse 代理服务的调用范围，不会阻止代码直接使用 Bun、Node 文件或网络接口。进程隔离用于故障边界；安装提示不能将它描述为 Wasm 权限沙箱。

## 开发验收

```sh
./cove studio plugins verify
./cove build Editor --mac
./cove test Engine --filter BunRuntimeTests
```

公开 SDK 的测试包含外部目录构建、持久实例调用、输入边界、多会话并发、取消与状态恢复。

## 在会话里创建插件

AI 插件提供读取 SDK、写入插件源码、构建和打开安装审阅的工具。生成的项目保存在 AI 插件自己的 `development/` 目录，构建产物保存在 `packages/`。安装审阅展示包的代码、契约、资源及宿主服务声明，用户选择启用后才运行代码。

应用携带独立 SDK 构建工具。`InvocationContext.storageDirectory` 提供插件的应用存储目录，`sdkDirectory` 提供公开 SDK 文档和 `cli.js`，无需访问编辑器源码。组件树可声明宽度、最大宽度、最小高度、语义背景、圆角及多行输入。

安装确认后，应用复制审阅过的包并保存应用级安装记录。插件在已加载的项目间同步启停，重启时按原状态恢复；代码、契约、权限或资源变化后需要重新审阅。停用保留包和数据，卸载移除安装。项目中的授权文件本身不会触发自动执行。
