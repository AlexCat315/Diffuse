# Vec3Field

`Vec3Field` is the compact three-axis numeric editor used by Inspector rows.
It combines three `NumberField` controls with colored X/Y/Z axis
labels, so transform values stay inside narrow property grids.

```swift
Vec3Field(x: $positionX, y: $positionY, z: $positionZ)
```

## When To Use

- Transform, bounds, velocity, or any fixed X/Y/Z vector.
- Property-grid cells where three independent `NumberField` controls would
  otherwise overflow the row.

## Narrow Layout

Each axis keeps a 96pt flex basis and an 88pt minimum width. A wide row keeps
X/Y/Z on one line; when the row cannot hold all three cells, the flex line wraps
X/Y first and puts Z on the next line. Very narrow containers wrap one axis per
line. Fields are never clipped below their editing width, and the same bound
inputs survive the reflow.

`NarrowReflowTests.vec3Reflow` checks 220pt (X/Y then Z) and 420pt (one row)
geometry. Gallery `--component vec3Field` includes a 240pt mixed-value example
and a full-width example for the same comparison.

## Scrub, Reset And Copy/Paste

Each axis is a `NumberField` whose colored axis chip is the scrub handle: drag
it horizontally to change that axis (one step per 4pt; Shift ×10, Option ×0.1
when held at press). With `resetValue: SIMD3(0, 0, 0)`, double-clicking a chip
resets that axis. Right-clicking the row offers Copy Vector (locale-independent
`1, -2.5, 0`), Paste Vector (accepts `1, 2, 3`, `(1 2 3)`, `[1;2;3]` and
`Vector3(1, 2, 3)`; disabled when the clipboard does not parse) and Reset.
Chip and text share one rounded border, focus ring and the touch/text-scale
height; the text fields are labeled X, Y and Z for assistive clients.
`Vec3FieldTests` cover scrub math, parsing, a real chip drag, double-click reset
and paste through the menu.

## Notes

- Defaults to `.small` text-field sizing and two decimal places.
- Supports the same min/max/step normalization path as `NumberField`.
