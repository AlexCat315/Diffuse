# Keep a complete prior checkout if downloading the pinned revision fails.
find_package(Git REQUIRED)
if(EXISTS "${REPO_DIR}/.git")
    execute_process(COMMAND ${GIT_EXECUTABLE} describe --tags --exact-match
        WORKING_DIRECTORY "${REPO_DIR}" OUTPUT_VARIABLE PLUTOVG_CURRENT
        OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET RESULT_VARIABLE PLUTOVG_STATUS)
    if(PLUTOVG_STATUS EQUAL 0 AND PLUTOVG_CURRENT STREQUAL PLUTOVG_VERSION)
        return()
    endif()
endif()
set(PLUTOVG_PENDING "${REPO_DIR}-pending")
file(REMOVE_RECURSE "${PLUTOVG_PENDING}")
execute_process(COMMAND ${GIT_EXECUTABLE} clone --depth=1 --branch "${PLUTOVG_VERSION}"
    https://github.com/sammycage/plutovg.git "${PLUTOVG_PENDING}"
    COMMAND_ERROR_IS_FATAL ANY)
file(REMOVE_RECURSE "${REPO_DIR}")
file(RENAME "${PLUTOVG_PENDING}" "${REPO_DIR}")
