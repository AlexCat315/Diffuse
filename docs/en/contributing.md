---
path: /en/docs/contributing
title: Contributing
description: A focused workflow for documentation, test, and code contributions.
locale: en
translationKey: docs.contributing
category: Community
order: 80
kind: doc
---

# Contributing

Guava Engine is licensed under Apache-2.0. Keep changes focused and add proportionate verification for behavior changes.

## Suggested workflow

1. Create a feature branch from the current target branch.
2. Run `python bootstrap.py` for a first native setup.
3. Modify only the packages related to the goal.
4. Run the relevant Swift package tests.
5. Describe behavior, validation, and tested platforms in the change summary.

```bash
swift test --package-path Engine
swift test --package-path GuavaUI
swift test --package-path Editor
swift build --package-path guava-mcp
```

Changes to C/C++ bridges or third-party versions should include a forced native rebuild on affected platforms. Core website documents keep matching `translationKey` values across Chinese and English.

## Swift maintainability

Organize classes and structs by responsibility: at most 20 stored properties, 16 initializer parameters, and 20 properties copied or decoded by an initializer. Split configuration and state into typed groups that own their defaults and validation. Copy whole groups and serialize the typed groups directly instead of maintaining parallel runtime, editor, and manifest field lists. This early-stage project updates callers and formats together; do not add old API aliases or format migration layers. Separate transient state from persisted settings.

Run `python3 scripts/check-swift-maintainability.py` to reject new oversized declarations and growth of existing ones. Use `--report` to inspect remaining historical debt. Baseline allowances may shrink as code is refactored; do not increase them to bypass the guard. The complete rules are in the repository's root `AGENTS.md`.
