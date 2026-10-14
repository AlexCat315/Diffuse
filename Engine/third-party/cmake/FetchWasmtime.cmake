# The platform catalog and staging implementation are shared with standalone cross builds.
find_package(Python3 COMPONENTS Interpreter REQUIRED)
add_custom_target(stage_wasmtime ALL
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/../wasmtime/stage.py"
        --platform "${GUAVA_TRIPLE}"
        --vendor "${GUAVA_VENDOR_DIR}"
        --cache "${CMAKE_BINARY_DIR}/wasmtime"
    COMMENT "Staging pinned static Wasmtime Component runtime for ${GUAVA_TRIPLE}"
    VERBATIM
)
