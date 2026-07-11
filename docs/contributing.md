---
path: /zh/docs/contributing
title: 参与贡献
description: 为 Guava Engine 提交文档、测试和代码变更的建议流程。
locale: zh
translationKey: docs.contributing
category: 社区
order: 80
kind: doc
---

# 参与贡献

Guava Engine 采用 Apache-2.0 许可证。贡献前请确保变更边界清晰，并为行为变化提供对应验证。

## 推荐流程

1. 从最新目标分支创建功能分支。
2. 首次运行 `python bootstrap.py` 准备原生依赖。
3. 只修改与目标相关的包，避免混合无关重构。
4. 运行对应 Swift 包的测试。
5. 在提交说明中写明行为变化、验证方式与平台。

## 常用验证

```bash
swift test --package-path Engine
swift test --package-path GuavaUI
swift test --package-path Editor
swift build --package-path guava-mcp
```

涉及 C/C++ 桥接或第三方版本时，至少在受影响平台重新运行 `python bootstrap.py --force`。文档贡献应保持中英文核心页面的 `translationKey` 对齐。
