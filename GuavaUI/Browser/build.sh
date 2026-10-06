#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# The compiler and SDK versions must match. Override for another installed pair.
sdk="${GUAVA_WASM_SDK:-swift-6.4.0-RELEASE_wasm}"
configuration="${GUAVA_WASM_CONFIGURATION:-debug}"
python3 build_fonts.py
export GUAVA_TEXT_ARTIFACT_ROOT="../Browser/.build/font-vendor"
exports=(guava_render guava_set_scale guava_font_alloc guava_font_load guava_atlas guava_atlas_size
         guava_pointer guava_key guava_text guava_vertices guava_vertex_bytes
         guava_indices guava_index_count guava_snapshot guava_snapshot_size
         guava_alloc guava_free guava_dispatch guava_response guava_response_size
         guava_events guava_hello guava_shader guava_shader_size)
flags=()
for symbol in "${exports[@]}"; do flags+=(-Xlinker "--export=$symbol"); done
if [[ "$configuration" == "release" ]]; then flags+=(-Xlinker --strip-debug); fi

swift build --build-system native --swift-sdk "$sdk" -c "$configuration" \
  --product GuavaUIBrowserPrototype -Xcxx -fno-exceptions -Xswiftc -static-stdlib \
  -Xcc -mexception-handling -Xlinker -lsetjmp \
  -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor "${flags[@]}"
bin_path="$(swift build --build-system native --swift-sdk "$sdk" -c "$configuration" --show-bin-path)"
output="${GUAVA_WASM_OUTPUT:-dist}"
mkdir -p "$output/wasi" "$output/devtools"
mkdir -p "$output/fonts"
cp ../Text/Fonts/* "$output/fonts/"
cp "$bin_path/GuavaUIBrowserPrototype.wasm" "$output/guava.wasm"
cp web/* "$output/"
cp node_modules/@bjorn3/browser_wasi_shim/dist/* "$output/wasi/"
cp node_modules/@bjorn3/browser_wasi_shim/LICENSE-* "$output/wasi/"
cp ../DevTools/index.html ../DevTools/app.js ../DevTools/styles.css ../DevTools/browser-connection.js ../DevTools/inspection.js "$output/devtools/"
printf 'Browser prototype built: npm run serve, then open http://127.0.0.1:8080\n'
