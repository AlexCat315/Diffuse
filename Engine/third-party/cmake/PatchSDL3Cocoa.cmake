# SDL's macOS 26 workaround must preserve the position of each queued event.
# Keep this patch reproducible on a fresh submodule checkout, and fail if an
# upstream change makes it inapplicable instead of silently building stale input.
find_package(Git REQUIRED)
set(SDL3_COCOA_PATCH "${CMAKE_CURRENT_LIST_DIR}/../patches/sdl3-cocoa-event-coordinate.patch")
if(NOT SDL3_PATCH_SOURCE_DIR)
    message(FATAL_ERROR "SDL3_PATCH_SOURCE_DIR must point at the disposable build-tree copy")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${SDL3_COCOA_PATCH}")
execute_process(
    COMMAND "${GIT_EXECUTABLE}" apply --check "${SDL3_COCOA_PATCH}"
    WORKING_DIRECTORY "${SDL3_PATCH_SOURCE_DIR}"
    RESULT_VARIABLE SDL3_COCOA_PATCH_CHECK
    ERROR_QUIET
)
if(SDL3_COCOA_PATCH_CHECK EQUAL 0)
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" apply "${SDL3_COCOA_PATCH}"
        WORKING_DIRECTORY "${SDL3_PATCH_SOURCE_DIR}"
        RESULT_VARIABLE SDL3_COCOA_PATCH_RESULT
        ERROR_VARIABLE SDL3_COCOA_PATCH_ERROR
    )
    if(NOT SDL3_COCOA_PATCH_RESULT EQUAL 0)
        message(FATAL_ERROR "Could not apply SDL3 Cocoa event-coordinate patch: ${SDL3_COCOA_PATCH_ERROR}")
    endif()
else()
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" apply --reverse --check "${SDL3_COCOA_PATCH}"
        WORKING_DIRECTORY "${SDL3_PATCH_SOURCE_DIR}"
        RESULT_VARIABLE SDL3_COCOA_PATCH_REVERSE_CHECK
        ERROR_QUIET
    )
    if(NOT SDL3_COCOA_PATCH_REVERSE_CHECK EQUAL 0)
        message(FATAL_ERROR "SDL3 Cocoa event-coordinate patch no longer matches the submodule. Review the patch before rebuilding SDL3.")
    endif()
endif()
