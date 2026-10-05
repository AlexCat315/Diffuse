# Lunasvg 3.5.0 bundles plutovg 1.3.1. Use the latest compatible release
# without changing the upstream Lunasvg source or relying on a system library.
find_package(Git REQUIRED)
# This directory is vendored source, not an initialized Git submodule.
file(REMOVE_RECURSE "${REPO_DIR}")
execute_process(
    COMMAND ${GIT_EXECUTABLE} clone --depth=1 --branch "${PLUTOVG_VERSION}"
        https://github.com/sammycage/plutovg.git "${REPO_DIR}"
    COMMAND_ERROR_IS_FATAL ANY
)
