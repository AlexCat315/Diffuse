#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# The compiler and SDK versions must match. Override for another installed pair.
sdk="${GUAVA_WASM_SDK:-swift-6.4.0-RELEASE_wasm}"
configuration="${GUAVA_WASM_CONFIGURATION:-debug}"
exports=(guava_render guava_pointer guava_vertices guava_vertex_bytes
         guava_indices guava_index_count guava_snapshot guava_snapshot_size
         guava_alloc guava_free guava_dispatch guava_response guava_response_size
         guava_events guava_hello guava_shader guava_shader_size)
flags=()
for symbol in "${exports[@]}"; do flags+=(-Xlinker "--export=$symbol"); done

swift build --build-system native --swift-sdk "$sdk" -c "$configuration" \
  --product GuavaUIBrowserPrototype -Xswiftc -static-stdlib \
  -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor "${flags[@]}"
bin_path="$(swift build --build-system native --swift-sdk "$sdk" -c "$configuration" --show-bin-path)"
mkdir -p dist/wasi dist/devtools
cp "$bin_path/GuavaUIBrowserPrototype.wasm" dist/guava.wasm
cp web/* dist/
cp node_modules/@bjorn3/browser_wasi_shim/dist/* dist/wasi/
cp node_modules/@bjorn3/browser_wasi_shim/LICENSE-* dist/wasi/
cp ../DevTools/index.html ../DevTools/app.js ../DevTools/styles.css ../DevTools/browser-connection.js dist/devtools/
printf 'Browser prototype built: npm run serve, then open http://127.0.0.1:8080\n'
