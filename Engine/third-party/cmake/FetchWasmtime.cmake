# The platform catalog and staging implementation live in the first-party
# Tools/Developer Swift package; CMake only invokes the staging command.
if(DEFINED ENV{GUAVA_SWIFT_EXECUTABLE})
    set(GUAVA_DEV_SWIFT "$ENV{GUAVA_SWIFT_EXECUTABLE}")
else()
    find_program(GUAVA_DEV_SWIFT swift REQUIRED)
endif()
set(GUAVA_DEV_PACKAGE "${CMAKE_CURRENT_LIST_DIR}/../../../Tools/Developer")
add_custom_target(stage_wasmtime ALL
    COMMAND "${GUAVA_DEV_SWIFT}" run --package-path "${GUAVA_DEV_PACKAGE}" guava-dev plugins stage
        --platform "${GUAVA_TRIPLE}"
        --vendor "${GUAVA_VENDOR_DIR}"
        --cache "${CMAKE_BINARY_DIR}/wasmtime"
    WORKING_DIRECTORY "${GUAVA_DEV_PACKAGE}/../.."
    COMMENT "Staging pinned static Wasmtime Component runtime for ${GUAVA_TRIPLE}"
    VERBATIM
)
