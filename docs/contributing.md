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

## Swift 可维护性

类和结构体按职责组织，最多 20 个存储属性；初始化器最多 16 个参数，最多逐项赋值或解码 20 个属性。配置和状态按功能拆成独立的值类型，由各组拥有默认值和校验。复制整组配置，避免运行时、编辑器和存档各维护同一份字段表。项目处于早期开发，直接更新调用方和分组存档格式，不新增旧 API 别名或旧格式迁移层。运行状态与持久化配置分开。

运行 `python3 scripts/check-swift-maintainability.py` 检查新类型和已有类型是否超出限制。`--report` 显示尚未整理的历史代码；基线只能随着重构缩减，不能通过扩大额度绕过检查。完整规则见仓库根目录的 `AGENTS.md`。
