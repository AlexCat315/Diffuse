结论：
这段的大方向是对的，尤其你把终点收敛成 In-Memory MCP 单总线，这个判断我认可。
但现在这节最大的问题不是“功能还不够多”，而是协议层和治理层没写透。换句话说，真正该补的不是更多 API 名字，而是：权限、线程边界、版本一致性、异步任务、订阅同步、审计回放。
同时，也有几项我不建议继续补在 AI 章节里，应该拆回编辑器、资产管线或传输层。

一、我认为最该补的内容
1. 权限与审计模型

现在 source: enum { human, ai } 远远不够。
至少要补成一组完整元数据，不然后面 Timeline、回滚、冲突分析、权限控制都做不稳：

actor_type：human / ai / automation
actor_id
client_id
session_id
request_id
trace_id
approval_state：auto / previewed / user_approved / rejected
base_revision

也就是说，**“是谁发起的”**不能只靠 human/ai 二分，而要能追到“哪个客户端、哪次请求、基于哪个快照、是否用户确认过”。

另外，ai_chat 的“特权上下文注入”也别做成真正不可见的隐式能力。
它可以自动带上 selection://current、scene://active，但最好在 UI 上显示成 context attachments / context chips，让用户知道这次请求究竟带了什么上下文。

2. 线程模型与写入边界

这一项非常关键，现在文本里提到了异步 Job，但还没把线程所有权写死。

建议明确写进文档：

World 只能由主线程 / 编辑器线程写
LLM 请求、JSON 解析、截图编码、序列化、网络 I/O 全部后台 Job
后台线程只能生成 proposal / transaction
真正 commit 一律经 CommandQueue 回到主线程

不把这条写清楚，后面 ai_chat 接入 MCP 后很容易变成“后台线程偷偷改世界状态”，那就会出现 UI、渲染、物理、选择态互相踩的问题。

3. Revision / 冲突 / 回滚语义

你现在已经在提 Lazy Sync 了，那就必须补“版本语义”。

建议加入：

world_revision
snapshot_revision
base_revision
乐观并发冲突检测
stale command 拒绝 / 自动 rebase 策略
transaction 的原子范围
部分失败怎么处理
timeout / cancel 语义

简单说，AI 不是只会“读一下再写一下”，它会遇到这种情况：

先读了场景快照
用户手动又改了场景
AI 再按旧理解写入

没有 revision 机制，这种写入就会悄悄覆盖用户操作。
所以这部分是必须补的，而且比加更多工具名称更重要。

4. 订阅机制与增量同步

你已经意识到“每帧全局快照”不行，这是对的。
但 Lazy Sync 还差几块关键描述：

活跃客户端的注册 / heartbeat / lease 超时
Dirty Flag 要细分，不要只有一个全局 dirty
hierarchy
selection
transform
material
render settings
assets
支持事件订阅，而不是只支持“读一份全量快照”
selection_changed
entity_added
component_changed
render_finished
job_completed

也就是说，这里最好从“快照同步”升级成“revisioned read model + event subscription”。

5. 把长任务统一成 Job / Artifact 协议

这一点我非常建议补。

你现在 AI-2 写成：

Scene API
Asset API
Render API

这个分层在业务上能理解，但不建议继续往“动作函数表”方向膨胀。
否则后面会变成几十上百个动词：import_texture、compile_shader、bake_navmesh、render_sequence、build_probe……

更稳的做法是把 AI 接口层收敛成三种原语：

Read Resource：读资源 / 查询
Apply Transaction：提交可预览事务
Run Job：启动长任务，返回 job_id

然后所有耗时操作都变成 Job：

import
compile
bake
render
screenshot
sequence output

同时补：

job_id
status
progress
cancel
artifacts
failure_reason

这样 AI 层不会被一堆业务动词绑死。

6. 截图反馈不要写死成 “512x512 base64”

这个点我建议改。

“稳态帧截图回传”很有价值，但固定写成 512x512 base64 太实现细节了，而且会带来两个问题：

带宽和拷贝成本偏高
一旦后面要多尺寸、多格式、差分图、对比图，就要推翻重写

更好的写法是：

默认返回 artifact://<id>
可选附带 thumbnail
支持 before/after/diff
由客户端按需取二进制或 base64

也就是说，AI 章节应该写“Artifact 协议”，而不是写死某个图片返回格式。

7. 可观测性与回放

Command Timeline UI 这个方向是对的，但它不能只是 UI。

建议文档里加一句：
Timeline 的底层必须是 canonical audit log / replay log。

要记录的至少包括：

command meta
before/after revision
affected entity ids
preview accepted / rejected
latency
snapshot cost
screenshot/artifact refs
model/tool provenance

否则 Timeline 只是好看，出了问题还是没法复盘。