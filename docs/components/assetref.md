# AssetRefField / AssetDropTarget

`AssetDropTarget` registers a rectangular drop zone with
`AssetDropRegistryHolder.current`. Drag sources can submit an `AssetDropPayload`
on pointer-up; the topmost compatible target receives it.

`AssetRefField` is the Inspector-facing resource reference field. It displays
the current asset, exposes a clear action, and accepts compatible drops through
`AssetDropTarget`.

```swift
AssetRefField(
    value: $mesh,
    activePayload: $activeAssetDrag,
    acceptedKinds: ["mesh"],
    placeholder: "Drop mesh"
)
```

## Notes

- Empty `acceptedKinds` accepts every asset kind.
- The registry uses live node frames, so targets continue to work after layout
  changes without rebuilding a separate hit map.
