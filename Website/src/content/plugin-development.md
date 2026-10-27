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

可使用布局、滚动、文本、按钮、输入框、选择器、开关、折叠区域与表格。组件的 `key` 保持身份；`flex`、`width`、`maxWidth` 控制布局。事件携带 `action`、`arguments`、`value` 和当前控件的 `values`。密码输入使用 `secure`，诊断快照不会读取其值。

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
