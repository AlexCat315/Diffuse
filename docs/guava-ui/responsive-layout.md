# Responsive candidate layouts

`LayoutThatFits` applies several geometry algorithms to one child tree. It picks the first candidate whose measured size fits each specified axis, with the last candidate as the fallback. It changes placement without recreating alternate view trees, so child IDs, state, and focus survive a width change.

```swift
LayoutThatFits([
    StackLayout(.horizontal, spacing: 12, alignment: .leading),
    StackLayout(.vertical, spacing: 8, alignment: .topLeading)
]) {
    SearchField()
    ActionButtons()
}
```

`StackLayout` proposes an intrinsic main axis and the available cross axis to each child, then sums the resulting main dimensions. Thus a horizontal candidate reports when its natural width cannot fit instead of squeezing children until every candidate appears to fit. Vertical candidates allow width-dependent content to wrap. Spacing uses logical points, and leading/trailing placement follows inherited layout direction.

Candidates implement the public `Layout` measurement and placement protocol. They share the same subviews and the core measurement cache; evaluation stops at the first fitting candidate. An unspecified proposal axis imposes no fit limit. The final candidate may overflow if no arrangement can satisfy authored minimum or fixed dimensions. Use scrolling or change the content when that fallback overflow is inappropriate.

This API chooses layouts for the same content. A `ViewThatFits`-style container that chooses between distinct view hierarchies is a separate capability. `StackLayout` is a natural-size geometry algorithm; retain Box, Row, or Column for flex distribution and compression.
