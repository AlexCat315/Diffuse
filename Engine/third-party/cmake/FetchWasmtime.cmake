# The platform catalog and staging implementation live in the first-party
# Tools/Developer Swift package; CMake only invokes the staging command.
if(DEFINED ENV{COVE_SWIFT_EXECUTABLE})
    set(COVE_DEV_SWIFT "$ENV{COVE_SWIFT_EXECUTABLE}")
else()
    find_program(COVE_DEV_SWIFT swift REQUIRED)
endif()
set(COVE_DEV_PACKAGE "${CMAKE_CURRENT_LIST_DIR}/../../../Tools/Developer")
add_custom_target(stage_wasmtime ALL
    COMMAND "${COVE_DEV_SWIFT}" run --package-path "${COVE_DEV_PACKAGE}" cove-dev plugins stage
        --platform "${COVE_TRIPLE}"
        --vendor "${COVE_VENDOR_DIR}"
        --cache "${CMAKE_BINARY_DIR}/wasmtime"
    WORKING_DIRECTORY "${COVE_DEV_PACKAGE}/../.."
    COMMENT "Staging pinned static Wasmtime Component runtime for ${COVE_TRIPLE}"
    VERBATIM
)
