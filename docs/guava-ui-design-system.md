# GuavaUI Design System

Anchor document for the GuavaUI visual layer. The token taxonomy here is the
load-bearing contract; concrete colour values may evolve, but slot names and
their semantics must not change without updating both this file and every
built-in style that consumes them.

## 1. Surface ramp (5 layers + 2 shells)

GuavaUI surfaces are organised into a strict elevation ladder. Each layer is
exactly one perceptual notch above the layer below. Mixing layers that are
not adjacent causes visible "step" artifacts and should be treated as a bug.

| Slot              | Layer | Use                                                                            |
| ----------------- | ----- | ------------------------------------------------------------------------------ |
| `background`      | L0    | Outermost canvas, behind everything. Window/page fill.                         |
| `surfaceSunken`   | L0.5  | Recessed wells inside L1 (text-field interior, code blocks).                   |
| `surface`         | L1    | Default panel/card body. The "page" of the UI.                                 |
| `surfaceVariant`  | L1.5  | Inset zones inside L1 (toolbar fills, secondary button rest, list backgrounds).|
| `surfaceRaised`   | L2    | Cards / panels that lift above L1 (hovered cards, draggable items).            |
| `surfaceFloating` | L3    | Popovers, menus, dropdowns, tooltips.                                          |
| `surfaceOverlay`  | L4    | Modal sheets and full-screen overlays.                                         |

Foregrounds:

| Slot               | Use                                                            |
| ------------------ | -------------------------------------------------------------- |
| `onBackground`     | Body text on `background`.                                     |
| `onSurface`        | Body text on `surface`/`surfaceVariant`/`surfaceRaised`.       |
| `onSurfaceVariant` | Secondary / labels / captions on the same surfaces.            |
| `onSurfaceMuted`   | Disabled text and quaternary metadata.                         |

## 2. Accent ramp

The accent ramp is a four-stop hue ramp consumed directly by interactive
states. **Never** hand-mix `accent.lighter()` / `accent.darker()` at a call
site — pick the slot below.

| Slot            | Use                                              |
| --------------- | ------------------------------------------------ |
| `accentMuted`   | Translucent halo (focus/selection background).   |
| `accent`        | Resting fill of primary controls.                |
| `accentHover`   | Hover fill — one notch lighter than `accent`.    |
| `accentPressed` | Pressed fill — one notch darker than `accent`.   |
| `onAccent`      | Foreground on any accent fill (text/icon).       |

In dark mode `accent → accentHover` brightens; `accent → accentPressed`
darkens. In light mode the same ramp inverts so the eye reads the same
"hover lifts, press settles" semantic.

## 3. State layers

State layers are translucent overlays composed onto **any** surface using
`Color.composited(over:)`. They let one secondary/ghost control type adapt to
whatever surface it sits on without per-context colour math.

| Slot                 | Composition rule                       | Use                          |
| -------------------- | -------------------------------------- | ---------------------------- |
| `stateLayerHover`    | ~6–8% white in dark, ~6% black in light| Hover tint on neutral fills. |
| `stateLayerPressed`  | ~12–16% white / black                  | Pressed tint on neutral.     |
| `stateLayerSelected` | accent @ ~16–20% alpha                 | List/tree row selection.     |

Composition pattern:

```swift
let bg = theme.colors.surfaceVariant
    .composited(over: theme.colors.stateLayerHover)
```

Built-in styles using state layers: `SecondaryButtonStyle`, `GhostButtonStyle`,
`DestructiveButtonStyle` (hover/press), `DefaultListRowStyle`,
`DefaultTreeRowStyle` (hover/select).

## 4. Status colours

`success`, `warning`, `error`, `info` follow Tailwind's emerald / amber / red /
blue 500 (dark) and 600 (light) ramps. They are intentionally NOT in the
accent ramp — they are reserved for state communication and must never be
used as neutral chrome.

## 5. Structure tokens

| Slot           | Use                                                      |
| -------------- | -------------------------------------------------------- |
| `border`       | Default separator/border (1 px).                         |
| `borderStrong` | Border that needs to read against a busier surface.      |
| `divider`      | Hairline rules between sibling rows/sections.            |
| `focusRing`    | 2 px keyboard-focus border. Always replaces `border`.    |
| `selection`    | Generic selection halo (text editor, drag-select).       |
| `overlay`      | Scrim painted under a modal.                             |

## 6. Typography

| Token        | Size / Weight / LineHeight    | Use                                   |
| ------------ | ----------------------------- | ------------------------------------- |
| `display`    | 32 / bold / 38                | Marketing-tier headers; rare in app.  |
| `title`      | 22 / semibold / 28            | Window / dialog title.                |
| `headline`   | 16 / semibold / 22            | Section header.                       |
| `body`       | 13 / regular / 18             | Default running text.                 |
| `bodyStrong` | 13 / semibold / 18            | Button label, emphasised body.        |
| `caption`    | 11 / regular / 14             | Metadata, helper text.                |
| `label`      | 10 / medium / 13              | Form labels, table headers.           |
| `mono`       | 12 / regular / 16             | Code, key sequences.                  |

## 7. Spacing scale

`xs:4 sm:8 md:12 lg:16 xl:24 xxl:32`. All padding/gap modifiers in built-in
styles must pick from this scale; arbitrary pixel values are not allowed.

## 8. Radius scale

`none:0 sm:4 md:6 lg:10 xl:16 pill:9999`. `md` is the default for buttons,
text fields and panel chrome. `lg` is reserved for cards. `pill` is reserved
for chips and toggles.

## 9. Motion

| Slot           | Duration / Curve              | Use                                 |
| -------------- | ----------------------------- | ----------------------------------- |
| `fast`         | 80 ms / easeOut               | Micro-feedback (focus ring, hover). |
| `standard`     | 180 ms / standard             | Default state transitions.          |
| `slow`         | 320 ms / standard             | Layout-shifting transitions.        |
| `emphasized`   | (curve only)                  | Marketing emphasis curves.          |
| `standardEasing` | (curve only)                | Default cubic.                      |

## 10. Authoring rules

1. **Never** read raw `Color(red:green:blue:)` in a style or a component.
   Resolve through `theme.colors.*` or `SemanticColorRef`.
2. **Never** call `lighter()` / `darker()` / `mixed()` at a style call site
   to derive a state colour. Use the accent ramp or state-layer tokens.
   `Color.composited(over:)` is the only sanctioned pixel-level mix.
3. Built-in styles must consume `theme.spacing.*` / `theme.radius.*` only;
   no literal pixel padding.
4. `focusRing` always replaces `border` on focus. Do not stack a focus ring
   over an existing border (creates a 3 px composite line).
5. State-layer overlays are designed for surfaces, not text. Never use
   `stateLayerHover` as a foreground colour.
6. Adding a new colour slot requires: add to `ColorScheme`, add to both
   `DefaultDarkTheme` and `DefaultLightTheme`, add a `SemanticColorRef`
   accessor, and update this document.

## 11. File map

- `GuavaUI/Sources/GuavaUICompose/Theme/ColorScheme.swift` — slot taxonomy.
- `GuavaUI/Sources/GuavaUICompose/Theme/DefaultDarkTheme.swift` — dark palette.
- `GuavaUI/Sources/GuavaUICompose/Theme/DefaultLightTheme.swift` — light palette.
- `GuavaUI/Sources/GuavaUICompose/Theme/SemanticColor.swift` — `SemanticColorRef` accessors.
- `GuavaUI/Sources/GuavaUIRuntime/Color.swift` — `Color.composited(over:)` primitive.
