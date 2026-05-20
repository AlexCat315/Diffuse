# Builds FreeType (libfreetype.a) via ExternalProject and stages into
# vendor/CFreeType.artifactbundle/<triple>/.

include(ExternalProject)

set(FREETYPE_BUNDLE ${GUAVA_VENDOR_DIR}/CFreeType.artifactbundle)
set(FREETYPE_VARIANT ${FREETYPE_BUNDLE}/${GUAVA_TRIPLE})
set(FREETYPE_INSTALL_PREFIX ${CMAKE_BINARY_DIR}/freetype-install)

ExternalProject_Add(freetype_ep
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/freetype
    PREFIX ${CMAKE_BINARY_DIR}/freetype-ep
    INSTALL_DIR ${FREETYPE_INSTALL_PREFIX}
    CMAKE_ARGS
        -DCMAKE_INSTALL_PREFIX=${FREETYPE_INSTALL_PREFIX}
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DBUILD_SHARED_LIBS=OFF
        -DFT_DISABLE_ZLIB=ON
        -DFT_DISABLE_BZIP2=ON
        -DFT_DISABLE_PNG=ON
        -DFT_DISABLE_HARFBUZZ=ON
        -DFT_DISABLE_BROTLI=ON
)

if(WIN32)
    set(FREETYPE_LIB_FILENAME "freetype.lib")
else()
    set(FREETYPE_LIB_FILENAME "libfreetype.a")
endif()

add_custom_target(stage_freetype ALL
    DEPENDS freetype_ep
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${FREETYPE_VARIANT}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${FREETYPE_VARIANT}/lib
    COMMAND ${CMAKE_COMMAND} -E make_directory ${FREETYPE_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E copy
        ${FREETYPE_INSTALL_PREFIX}/lib/${FREETYPE_LIB_FILENAME}
        ${FREETYPE_VARIANT}/lib/${FREETYPE_LIB_FILENAME}
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${FREETYPE_INSTALL_PREFIX}/include/freetype2 ${FREETYPE_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_SOURCE_DIR}/cmake/templates/CFreeType.h
        ${FREETYPE_VARIANT}/include/CFreeType.h
    COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_SOURCE_DIR}/cmake/templates/CFreeType.modulemap
        ${FREETYPE_VARIANT}/include/module.modulemap
    COMMENT "Staging FreeType into ${FREETYPE_VARIANT}"
)

write_artifactbundle_info(${FREETYPE_BUNDLE} "CFreeType" "${GUAVA_TRIPLE}/lib/${FREETYPE_LIB_FILENAME}")
