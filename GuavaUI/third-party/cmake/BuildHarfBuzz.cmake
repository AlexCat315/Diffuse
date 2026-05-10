# Builds HarfBuzz (libharfbuzz.a) via ExternalProject (with FreeType integration)
# and stages into vendor/CHarfBuzz.artifactbundle/<triple>/.

include(ExternalProject)

set(HARFBUZZ_BUNDLE ${GUAVA_VENDOR_DIR}/CHarfBuzz.artifactbundle)
set(HARFBUZZ_VARIANT ${HARFBUZZ_BUNDLE}/${GUAVA_TRIPLE})
set(HARFBUZZ_INSTALL_PREFIX ${CMAKE_BINARY_DIR}/harfbuzz-install)

ExternalProject_Add(harfbuzz_ep
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/harfbuzz
    PREFIX ${CMAKE_BINARY_DIR}/harfbuzz-ep
    INSTALL_DIR ${HARFBUZZ_INSTALL_PREFIX}
    DEPENDS freetype_ep
    CMAKE_ARGS
        -DCMAKE_INSTALL_PREFIX=${HARFBUZZ_INSTALL_PREFIX}
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_PREFIX_PATH=${FREETYPE_INSTALL_PREFIX}
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DBUILD_SHARED_LIBS=OFF
        -DHB_HAVE_FREETYPE=ON
        -DHB_BUILD_TESTS=OFF
        -DHB_BUILD_UTILS=OFF
        -DHB_HAVE_GLIB=OFF
        -DHB_HAVE_ICU=OFF
        -DHB_HAVE_GRAPHITE2=OFF
        -DHB_HAVE_CORETEXT=OFF
)

add_custom_target(stage_harfbuzz ALL
    DEPENDS harfbuzz_ep
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${HARFBUZZ_VARIANT}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${HARFBUZZ_VARIANT}/lib
    COMMAND ${CMAKE_COMMAND} -E make_directory ${HARFBUZZ_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E copy
        ${HARFBUZZ_INSTALL_PREFIX}/lib/libharfbuzz.a
        ${HARFBUZZ_VARIANT}/lib/libharfbuzz.a
    # HarfBuzz installs headers under include/harfbuzz/. Flatten into include/
    # so consumers do `#include "hb.h"` directly (matches existing Swift code).
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${HARFBUZZ_INSTALL_PREFIX}/include/harfbuzz ${HARFBUZZ_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_SOURCE_DIR}/cmake/templates/CHarfBuzz.h
        ${HARFBUZZ_VARIANT}/include/CHarfBuzz.h
    COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_SOURCE_DIR}/cmake/templates/CHarfBuzz.modulemap
        ${HARFBUZZ_VARIANT}/include/module.modulemap
    COMMENT "Staging HarfBuzz into ${HARFBUZZ_VARIANT}"
)

write_artifactbundle_info(${HARFBUZZ_BUNDLE} "CHarfBuzz" "${GUAVA_TRIPLE}/lib/libharfbuzz.a")
