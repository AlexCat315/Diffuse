# Variable-height virtual layout

`VariableVirtualStack` accepts plain collection data, a stable ID key path, an exact row-height closure, and row content. It follows the explicit-size contract used by gpui-kit's variable `virtual_list`: the caller supplies each row's full height, and the container builds only visible rows plus overscan. It does not automatically measure offscreen views or estimate unknown heights.

```swift
VariableVirtualStack(messages, id: \.id, rowHeight: { message, width, scaler in
    message.height(for: width, fontSize: scaler.scale(14))
}, spacing: 4, scrollToIndex: selectedIndex) { message in
    MessageRow(message)
}
.frame(height: 400)
```

The closure receives the actual content viewport width in logical points, after the stable scrollbar lane, and the inherited `TextScaler`. Initial measurement waits until the first layout reports a positive viewport width, avoiding a full collection measurement at a provisional zero width. Give the container a bounded viewport. Use the same font and wrapping rules as the rendered row. Heights include row padding and decoration; spacing is added separately. Invalid heights become one logical point.

The private metric cache retains a Fenwick prefix-sum index. Offset lookup, prefix queries, and individual height updates are logarithmic. A fresh data input evaluates the size closure once per element; width or text-scale changes also invalidate sizes. Bulk invalidation rebuilds the index in linear time. Ordinary scrolling reuses all sizes and constructs only the current range. The cache and scroll state are transient and never enter authored or persisted data.

Each input update preserves the first intersecting row's stable ID and its offset within the row, then clamps to the new scroll extent. This keeps a viewport steady when rows above it change height or new rows are inserted. If that ID disappears, the old ordinal selects the nearest remaining row. `scrollToIndex` reveals a requested index when a real viewport is available; setting it to `nil` allows the same index to be requested again. A row taller than the viewport aligns its top.

IDs must be unique. Offscreen views are unmounted, so persistent edits and selection belong in the caller's model. Use `VirtualStack` for uniformly sized rows; use `VariableVirtualStack` when the application can provide exact varying sizes. Automatic self-sizing virtualization remains a separate capability.
