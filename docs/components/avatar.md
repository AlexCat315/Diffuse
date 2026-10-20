# Avatar / AvatarGroup

头像与头像组是独立公共组件，参考本机 GPUI Kit 的尺寸、姓名回退、稳定 OkLCH 色板与叠放行为。配色算法按本项目实现；示例人像为仓库内自绘 SVG。

```swift
Avatar("Jason Lee", id: "jason", imageURL: photoURL) {
    $0.diameter = 72
    $0.shape = .roundedRectangle(radius: 16)
    $0.borderWidth = 2
}

AvatarGroup(members) {
    $0.limit = 3
    $0.overflow = .count
    $0.overlap = 0.3
}
```

姓名、来源与外观由调用方持有。下载、加载阶段、取消任务及上传身份属于节点会话，不参与持久化。`AvatarAppearance` 和 `AvatarGroupOptions` 各自持有默认值与校验，头像组整值复制头像，只覆盖组统一直径。

## 行为契约

- 默认尺寸继承 `ControlSize`：mini 16、small 24、regular 48、large 80 点。自定义直径 12–512 点，形状支持圆形、方形和圆角矩形。边框 0–8 点，并受直径约束。
- 图片加载中、失败或未设置时显示姓名首字母；空姓名显示匿名矢量图标。图片采用 fill 中央裁切，圆角作用于容器边界。
- 首字母以 Swift grapheme 为单位：多词取前两词首字母，单词取前两个字符，转大写后仍限制两个 grapheme。规范等价 Unicode 使用相同色相；12 色在明暗主题下均通过 4.5:1 文字对比度测试。
- 头像本身不是按钮、不进入焦点链。辅助功能以完整姓名表示 image，隐藏内部首字母/图标；匿名头像有明确说明。
- 头像组默认显示 3 个，前面的成员绘制在后面的成员之上。重叠比例 0–0.7。超额部分可显示 `+N`、省略号或隐藏。计数项有完整数量语义和剩余姓名提示，提示最多取 20 个姓名。
- limit=0 时可仅显示超额项；隐藏超额项或空组自然尺寸为零。显式 `Avatar.id` 保持重排后的图片会话身份；未设置 ID 时使用位置身份。
- 改变来源立即切换至该来源的回退状态。旧请求即使解码结束也不能覆盖新来源；卸载后禁止上传和发布。`appearance.retryID` 改变后可重试失败请求。

## 验证与差距

`AvatarTests` 覆盖 Unicode/规范等价、全部主题色对比度、尺寸/形状、组边界/叠放/重排、圆形裁切顶点与 UV。`AsyncImageTests` 覆盖旧结果、卸载、重试、真实本机 HTTP 状态/流式限额/取消；加载器与解码器契约见 [Image](image.md)。

macOS Retina 原生画廊已检查：中文首字母、姓名色板、匿名图标、远程 GitHub 图片、缺图回退、四档尺寸、100 点圆角图片、方形头像、0/3 可见数量与 0.7 重叠、明暗主题。检查过程中发现的 Slider 固有高度已修正并加入回归测试。

macOS 的 Apple 彩色 emoji 已接入共享文字渲染，原生检查确认 `👩🏽‍💻 coder` 的头像首字母与下方姓名都可显示完整彩色字形。连字/肤色/旗帜/variation 序列、UTF-8 cluster、逻辑宽度与 1×/2× 栅格、选区/删除/撤销均有回归测试。Linux/Windows 已接入 FreeType COLRv0 与未压缩 BGRA 位图来源；PNG 压缩位图与 Wasm RGBA 尚未接入，具体范围与验证见 [文字与彩色字形](typography.md)。

## 状态角标与成员列表

```swift
Avatar("Jason Lee") { $0.status = .busy; $0.statusLabel = "In a meeting" }

AvatarGroup(members) {
    $0.limit = 3
    var list = AvatarMemberList()
    list.scope = .remaining          // 或 .all：完整名单
    list.onSelect = { open($0.id) }  // 省略时行只展示、不可点
    $0.memberList = list
}
```

- `AvatarStatus` 为 online / away / busy / offline，分别用实心、内缺口、横条与空心环区分，色盲与单色主题也能辨认；角标直径为头像的 28%（6–24 点），圆形头像的圆心落在 45° 轮廓上，方形贴角内收。外圈用 surface 色分隔。
- 角标按逻辑 `.end` 边定位，RTL 自动镜像到左下。读屏值为状态名（可用 `statusLabel` 覆盖），与姓名组合朗读；角标本身不可命中、不进焦点链。
- 设置 `memberList` 后溢出项变为按钮：辅助功能名称为“N more members”，展开态随弹层同步，悬停提示保留剩余姓名。弹层列出头像、姓名与状态，行高 ≥44；提供 `onSelect` 时行为按钮，选择后关闭。弹层呈现状态属节点会话，不进入持久化。
- `AvatarPresenceTests` 覆盖角标几何（LTR/RTL）、读屏值、自定义状态名、成员弹层的真实点击与静态溢出项；Gallery `avatar` 页提供四种状态与可选择的成员列表。

通用图片缓存的 LRU 淘汰与在途合并见 [Image](image.md)。
