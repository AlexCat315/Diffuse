# Vec3Field

`Vec3Field` is the compact three-axis numeric editor used by Inspector rows.
It combines three shrinkable `NumberField` controls with colored X/Y/Z axis
labels, so transform values stay inside narrow property grids.

```swift
Vec3Field(x: $positionX, y: $positionY, z: $positionZ)
```

## When To Use

- Transform, bounds, velocity, or any fixed X/Y/Z vector.
- Property-grid cells where three independent `NumberField` controls would
  otherwise overflow the row.

## Notes

- Defaults to `.small` text-field sizing and two decimal places.
- Supports the same min/max/step normalization path as `NumberField`.
