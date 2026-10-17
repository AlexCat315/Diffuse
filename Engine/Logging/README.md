# Guava 日志

GuavaLogging 是基于 [apple/swift-log](https://github.com/apple/swift-log) 的进程日志后端。业务代码使用标准 `Logger`、等级、metadata 和 source location；Guava 负责初始化、上下文、输出、回放和生命周期。日志不依赖 DevTools 是否启用。

## 应用里使用

普通 GuavaUI 应用只需现有的 `import GuavaUI`。`Application.run` 会在窗口和 GPU 初始化前安装后端，退出时刷盘。

```swift
import GuavaUI

let logger = LogSystem.logger("com.example.notes.document")
logger.info("Document opened", metadata: ["document_id": "notes-42"])
logger.error("Save failed", metadata: ["error": "\(error)"])
```

`LogSystem.logger` 返回标准 `Logging.Logger`，也适合在 `Application.run` 之前创建，因此启动期间的日志也能保留。应用安装后端后也可直接使用标准 `Logger(label:)`；swift-log 已创建的 Logger 不会自动更换 handler。SDK 库本身不调用 `LoggingSystem.bootstrap`。

应用通过现有配置调整有独立默认值的日志组：

```swift
var configuration = ApplicationConfiguration()
configuration.logging.filtering.minimum = .info
configuration.logging.filtering.modules["com.example.notes"] = .debug
configuration.logging.storage.maximumFileBytes = 8 * 1024 * 1024
configuration.logging.storage.filesPerSession = 3
// 将 configuration 传给现有 Application.run 调用。
```

独立工具、嵌入宿主可以直接依赖 `Engine/Logging` 的 `GuavaLogging` product：

```swift
import GuavaLogging

var configuration = LoggingConfiguration()
try configuration.applyEnvironment()
try LogSystem.bootstrap(application: "com.example.worker", configuration: configuration)
defer { LogSystem.flush() }
let logger = Logger(label: "com.example.worker")
```

同一进程的重复初始化安全；配置相同时不会重开文件，进程后端只安装一次。如果宿主已安装其他 swift-log 后端，应在 Guava 配置中选择 `.installation = .local`：Guava SDK 的 `LogSystem.logger`、原生日志和 Guava 订阅继续工作，宿主自己的标准 Logger 仍由原来的后端处理。不要对 swift-log 再次 bootstrap。

## 上下文与记录

```swift
try await LogContext.withValues(["operation_id": "save-42", "document_id": "notes-42"]) {
    logger.info("Saving")
    try await saveDocument()
}
```

上下文使用 TaskLocal，支持嵌套和结构化并发，不修改 Logger 的共享 metadata。优先级为：TaskLocal、metadataProvider、Logger metadata、单次调用 metadata；后者覆盖前者。`Task.detached` 和独立线程不会自动继承 TaskLocal，跨执行器时可显式复制 `LogContext.current`。CLI 的子进程适配器已处理这一步。

每条 `LogRecord` 包含进程内单调 sequence、Unix 时间、七级 severity、模块 label、message、保留数组/对象结构的 metadata、file/function/line/source，以及 pid/application/runID。CLI 启动桌面或 Android 应用时传递 runID；子进程另有 child_pid/stream/command metadata。sequence 只在同一进程内排序，不能当跨进程全局序号。

首次 bootstrap 会给保留的启动日志补齐正式 application/runID，再回放到文件；Android 在 onResume 早于 Surface 创建时也保持同一关联身份。PluginHost 继承 runID，其 stderr 独立排空并转发到父进程日志，RPC stdout 保持帧协议；SourceKit-LSP stderr 在 debug 等级提供，并继续保留原有错误尾部。

默认递归遮盖 metadata 中 password/token/secret/authorization/cookie/api_key 等键，大小写不敏感；`redaction.keys` 可以扩充。消息正文中的任意字符串不做秘密识别，调用方应把凭据放入可遮盖的 metadata，并避免记录敏感正文。消息、metadata、源位置和身份字符串都有大小限制；超限会截断，metadata 深度和节点数量也有界。

## 输出和可靠性

| 输出 | 行为 |
| --- | --- |
| 控制台 | 默认可读文本，桌面写 stderr；可选 JSONL。Android 使用 logcat `Guava` tag，保留 severity，并按 UTF-8 边界分块。 |
| 文件 | 默认开启，逐行 JSON，独立应用目录和进程会话目录，轮转且限制保留会话数。 |
| 内存历史 | 默认保留最近 512 条，Inspector 晚连接也可回放。 |
| Inspector | 桌面/Android WebSocket 和 Wasm MessageChannel 使用同一 LogRecord，支持过滤、详情、暂停显示和导出 JSONL。 |
| Editor Console | 接收引擎日志；领域错误原有 target/detail/nextStep 保留，避免重复回灌。控制台记录不进入项目持久化。 |

默认目录：macOS `~/Library/Logs/Guava`，Linux `$XDG_STATE_HOME/guava/logs`（默认 `~/.local/state/guava/logs`），Windows `%LOCALAPPDATA%/Guava/Logs`。Android 使用应用私有 `files/logs`，由宿主确定设备路径；Wasm 关闭文件输出，使用浏览器控制台、内存历史和导出。路径结构为 `<root>/<application>/session-<UUID>/events.jsonl`。

单会话默认最多 3 个 8 MiB 文件，保留最近 3 个会话。文件权限默认 0600，目录 0700；Windows 使用宿主的文件权限。清理仅针对带 Guava lease 标记且未被占用的会话，不删除活动进程的日志；因此并发活动会话可以临时超过保留数量。文件写入失败会关闭该文件输出，记录失败计数并保留控制台和历史。

原生平台通过串行后台队列处理格式化、文件和订阅，待写队列默认最多 1024 条。饱和时丢弃并计数；error/critical 优先保留最新记录，同时向控制台应急输出。后续汇报 dropped/total_dropped，`LogSystem.status` 可读取写入、丢弃、待写和文件失败数量。error/critical 默认同步刷盘，可通过 `storage.flushOnError` 调整。正常退出、Android onPause 和显式 `LogSystem.flush()` 会排空当前待写批次并同步文件。强制终止或系统断电仍可能损失未刷盘的尾部；这不是崩溃报告采集器。

`LogSystem.observe(query:replay:receive:)` 返回可取消、析构时自动取消的订阅。回放与注册在同一 writer 上执行，避免订阅间隙。回调在日志 writer 上，应该快速入队；不要在回调里等待其他线程。Editor 和 Inspector 已各自实现有界收件箱，慢客户端的损失通过 `log.gap` 报告，不阻塞应用日志 writer。

## 环境配置

```bash
GUAVA_LOG_LEVEL=debug guava run MyApp --mac
GUAVA_LOG_MODULES='{"com.guava.engine.rhi":"debug"}' guava run MyApp --android --profile --devtools
GUAVA_LOG_FORMAT=json GUAVA_LOG_DIRECTORY=/tmp/guava-logs guava doctor
```

| 变量 | 值 |
| --- | --- |
| `GUAVA_LOG_LEVEL` | trace/debug/info/notice/warning/error/critical，默认 info |
| `GUAVA_LOG_MODULES` | JSON 对象，模块前缀到等级；最长路径段前缀匹配 |
| `GUAVA_LOG_CONSOLE` / `GUAVA_LOG_FILES` | 1/0、true/false、yes/no |
| `GUAVA_LOG_FORMAT` | text/json |
| `GUAVA_LOG_DIRECTORY` | 文件根目录；Android 会改为设备私有目录 |
| `GUAVA_LOG_RUN_ID` | CLI/子进程的关联 ID，通常自动生成 |

配置通过验证后才应用。CLI 的结果、帮助和机器可读 stdout 不混入诊断；子进程的人类输出 tee 到原流并记入 JSONL，控制台不会重复打印。命令参数不默认记录，避免把认证参数带入日志。

## 模块边界和验证

`GuavaLogCore` 只拥有配置、记录、上下文和查询；`GuavaLogging` 拥有后端、输出和订阅；`CGuavaLog` 适配 C/JNI/平台控制台和文件 lease。Portable 协议只依赖 Core，浏览器不引入 NIO，Editor 与 DevTools 都是日志消费者。原生代码使用 `GuavaLog.h` 的 `GUAVA_LOG/GUAVA_LOGF`，SDL 回调和 Android Java RuntimeLog 接入同一后端。

```bash
swift test --package-path Engine/Logging
swift test --package-path Tools/Guava
swift test --package-path GuavaUI/Portable
swift test --package-path Editor --filter ConsoleLoggingTests
swift run --package-path Tools/Developer guava-dev validate session /path/to/App mac
swift run --package-path Tools/Developer guava-dev validate session /path/to/App android
swift run --package-path Tools/Developer guava-dev android logging /path/to/App
```
