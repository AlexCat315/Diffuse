# 浏览器插件执行

浏览器不加载 Wasmtime 的本机静态库。这个目标将 Cove 的同一个 `.coveplugin` Component 包在应用构建时转换为 core Wasm 和可信胶水代码，并在专用 Module Worker 中执行。固定使用 Bytecode Alliance Jco 1.37.0，依赖树由 `package-lock.json` 锁定。

准备与打包，在仓库根目录运行：

```sh
swift build --package-path Engine --product DiffusePluginHost
npm ci --prefix Platforms/Web/Plugins --ignore-scripts
node Platforms/Web/Plugins/src/packaging/entry.js \
  path/to/example.coveplugin path/to/new-web-output \
  "$(swift build --package-path Engine --show-bin-path)/DiffusePluginHost"
```

输出目录必须是新目录，避免覆盖已经发布的包。工具先复制运行时插件包（manifest、WIT、component 及可选的已声明资源），再调用原生宿主校验 manifest、WIT、Component 实际类型和 imports；随后让 Jco 生成可重复实例化的模块。没有第二套 WIT 解析器。core Wasm 内存和表的最大值在打包时写入二进制；不允许 shared memory 或 memory64。

把输出和 `src/runtime/` 随应用一起部署。`plugin.web.integrity` 是 `plugin.web.json` 的 SHA256，需要在应用可信构建流程中写入应用自己的插件目录/配置。运行时不接受插件自带哈希作为信任依据，也不要在运行时从未知插件服务器读取这个值后直接信任它。生成的 JS 只能来自受信任的应用打包流程；用户上传插件时，应在受控构建环境中从原始 Component 重新生成并发布经过审核的目录条目。

```js
import { WebPluginSession } from './runtime/session.js';

// 构建时写入应用自己的可信目录，不能取自用户上传的插件。
const integrity = applicationPluginCatalog['safe.reader'];
const url = './plugins/reader/plugin.web.json';
const inspected = await WebPluginSession.inspect(url, integrity);
// 由应用展示 inspected.inspection，并取得用户对该精确版本的授权。
const authorization = inspected.authorization;
const plugin = await WebPluginSession.open(url, { integrity, authorization });
const result = await plugin.prepare('safe.reader.inspect', { enabled: true });
```

每次 `prepare` 都创建新 Worker 与新 Wasm 实例；调用结束、报错、取消或超时后销毁 Worker。输入按 Swift 导出的 WIT 类型严格校验并适配 Jco 的字段命名。查询只收到本次调用获准的 JSON 快照，不接收场景对象、文件系统、网络、WASI 或写入 API：

```js
const result = await plugin.prepare('safe.reader.inspect', { enabled: true }, {
  snapshot: {
    sceneRevision: 42,
    values: { 'cove:scene/query': { entities: [], revision: 42 } },
  },
  signal: abortController.signal,
  timeoutMilliseconds: 1000,
});
```

读取结果为 `{kind: 'read', value}`。写入插件的结果为 `{kind: 'hostCalls', calls}`，仍只是准备结果；运行时使用原生导出的 host contracts 验证精确授权、版本与参数 schema，实际提交由应用自己的能力执行入口负责。

限制：单次输入/输出最多 1 MiB、查询快照合计 512 KiB、单个线性内存最多 64 MiB、单个表最多 10,000 元素、最多 64 个 core modules，每个模块最多 16 个内存/表，默认超时 5 秒。浏览器 WebAssembly 没有 Wasmtime 的 instruction fuel 和 epoch API，这里通过 Worker 终止执行 wall-clock deadline；这不是浏览器进程总内存上限，也不提供独立 OS 进程的崩溃隔离。需要 HTTPS/localhost、Module Worker、WebAssembly 和 Web Crypto；CSP 必须允许可信 Worker、Wasm 编译以及校验后生成的 blob 模块。

验证：

```sh
npm test --prefix Platforms/Web/Plugins
swift run --package-path Tools/Developer cove-dev browser web-plugins \
  --host "$(swift build --package-path Engine --show-bin-path)/DiffusePluginHost" \
  --probe Engine/build/plugin-probe/CovePluginProbe
```

`COVE_CHROMIUM` 可指定已有 Chromium 可执行文件。浏览器测试覆盖真实 Component 执行、强类型输入、查询授权、授权失效、文件篡改、无限循环超时、取消及恢复。此目标提供插件执行能力，不代表 `cove build --web` 已实现完整的 Web 应用交付。
