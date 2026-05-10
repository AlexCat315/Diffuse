# Builds Yoga (libyogacore.a) and stages into vendor/yoga.artifactbundle/<triple>/.

set(YOGA_BUNDLE ${GUAVA_VENDOR_DIR}/yoga.artifactbundle)
set(YOGA_VARIANT ${YOGA_BUNDLE}/${GUAVA_TRIPLE})

set(YG_ENABLE_REFLECTION OFF CACHE BOOL "" FORCE)
# Pull Yoga's project-defaults manually (sets compile flags etc.), then include
# only the yoga/ subdir — bypasses Yoga's root CMakeLists which unconditionally
# adds tests/ that drag in googletest with broken install rules.
include(${CMAKE_SOURCE_DIR}/yoga/cmake/project-defaults.cmake)
add_subdirectory(${CMAKE_SOURCE_DIR}/yoga/yoga yoga-build)

install(TARGETS yogacore
    ARCHIVE DESTINATION ${YOGA_VARIANT}/lib
    LIBRARY DESTINATION ${YOGA_VARIANT}/lib
)

# Yoga public headers live under upstream/yoga/ (.h files at top level + bundled
# module.modulemap). Copy them into the artifactbundle's include/yoga/ subdir
# and let SPM's binaryTarget pick up the bundled modulemap.
install(DIRECTORY ${CMAKE_SOURCE_DIR}/yoga/yoga/
    DESTINATION ${YOGA_VARIANT}/include/yoga
    FILES_MATCHING
    PATTERN "*.h"
    PATTERN "module.modulemap"
)

write_artifactbundle_info(${YOGA_BUNDLE} "yoga" "${GUAVA_TRIPLE}/lib/libyogacore.a")
