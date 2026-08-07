---
path: /en/docs/guava-ui
title: GuavaUI design system
description: Surface hierarchy, color, spacing, motion, and component contracts in GuavaUI.
locale: en
translationKey: docs.guava-ui
category: Reference
order: 60
kind: doc
---

# GuavaUI design system

GuavaUI is a SwiftUI-style declarative interface system. Its design system defines behavior across layout, input, focus, and motion—not only visual values.

## Surface hierarchy

`ColorScheme` defines `background`, `surface`, `surfaceVariant`, `surfaceSunken`, `surfaceRaised`, `surfaceFloating`, and `surfaceOverlay`. Components consume semantic colors rather than calculating one-off lighter and darker variants.

## Shared contracts

- Interactive controls provide at least a 32pt hit height and a visible focus ring.
- Text input is vertically centered, clipped, and inset with theme spacing.
- Hover, pressed, selected, and focused appearances use composited state layers.
- Box, Row, and Column do not participate in hit testing by default.

Editor panels additionally follow a workbench contract: toolbars use a 34pt minimum height and shared horizontal insets; search rows provide clearing and result counts; icon-only actions provide tooltips; and no-data, no-selection, and zero-result states explain the empty surface instead of leaving it blank.

Detailed component contracts are currently maintained in Chinese. See the [component overview](components/index.md) for the coverage list.
