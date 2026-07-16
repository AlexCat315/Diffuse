if(NOT EXISTS "${LIBRARY_FILE}")
    message(FATAL_ERROR "Wasmtime library missing while writing provenance manifest")
endif()

file(SHA256 "${LIBRARY_FILE}" LIBRARY_SHA256)
file(WRITE "${OUTPUT_FILE}" "{
  \"name\": \"Wasmtime\",
  \"version\": \"${VERSION}\",
  \"source\": {
    \"url\": \"${ARCHIVE_URL}\",
    \"sha256\": \"${ARCHIVE_SHA256}\"
  },
  \"artifact\": {
    \"sha256\": \"${LIBRARY_SHA256}\",
    \"install_name\": \"@rpath/libwasmtime.dylib\",
    \"platform\": \"macos\",
    \"architecture\": \"${ARCHITECTURE}\"
  },
  \"packaging\": {
    \"tool\": \"xcodebuild -create-xcframework\",
    \"linkage\": \"dynamic\"
  },
  \"runtime_policy\": {
    \"component_model\": true,
    \"wasi_linked\": false,
    \"ambient_filesystem\": false,
    \"ambient_network\": false
  }
}
")
