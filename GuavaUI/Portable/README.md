# GuavaUI portable modules

These packages share real desktop implementations with Swift/Wasm without SDL,
GPU drivers or native font libraries. Scene and Compose targets use Yoga C++.

- `GuavaUICore`: State/Binding, color, DrawList, WGSL, font values, glyph metrics
  and text layout. FreeType/HarfBuzz live in the separate [Text](../Text/README.md)
  package, which Runtime re-exports and the browser also uses.
- `GuavaUIScene`: Node/RenderTree, Yoga layout, recomposition, animation,
  hit testing, focus, pointer capture and input dispatch.
- `GuavaUIComposeCore`: View/ViewBuilder, ViewGraph, CompositionLocal and boxes/stacks.
- `GuavaUISharedDemo`: one Compose counter and text-input source for both hosts.
- `GuavaUIDevToolsScene`: actual SceneInspector, with stable element identifiers.
- `GuavaUIDevToolsProtocol`: wire types, session validation/subscriptions,
  state differences and bounded Codable input recordings.
- `GuavaUIDevToolsServer`: shared requests and injectable transport. The default
  SwiftNIO WebSocket transport supports macOS, Linux and Windows.
- `GuavaUIDevToolsProbe`: headless synthetic scene/state provider for server checks.

Pure platform input types live in `Engine/PlatformCore`. Desktop EngineKernel,
PlatformShell, Runtime, Compose and DevTools re-export their shared implementations.
The socket transport is never compiled into the [browser](../Browser/README.md).

```bash
swift test --package-path GuavaUI/Portable
swift run --package-path GuavaUI/Portable GuavaUIDevToolsProbe
```

Open `GuavaUI/DevTools/index.html`, connect to `ws://127.0.0.1:9229/`.
Pass a port to the probe to override it. Port zero binds an available port;
`DevServer.boundPort` reports it. The actual shared counter desktop host is
`GUAVA_DEVTOOLS=1 swift run --package-path GuavaUI GuavaUIDemo --shared-counter`.

WebSocket messages are bounded to 1 MiB. Fragmented text, ping/pong and writer
backpressure are supported. Streams remain opt-in per connection. Disconnecting
clears that connection's selection/recording; the last mirror disconnect stops capture.
Native callbacks use the UI-thread scheduler, including synchronous SDL loops.
Hosts can supply `stateRestoreResultHandler` to acknowledge only validated restores.
Input recording/replay requires host callbacks and advertises a separate `recording`
capability; timestamps are metadata and replay currently delivers events in order.
