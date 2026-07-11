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
