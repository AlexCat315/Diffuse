# Builds Imath + OpenEXR statically using ExternalProject (so Imath is fully
# installed before OpenEXR's find_package(Imath) runs).
# Output goes to Engine/vendor/ocio_openexr/<triple>/.

include(ExternalProject)

set(OCIO_OPENEXR_BUNDLE ${GUAVA_VENDOR_DIR}/ocio_openexr)
set(OCIO_OPENEXR_VARIANT ${OCIO_OPENEXR_BUNDLE}/${GUAVA_TRIPLE})
set(IMATH_INSTALL_PREFIX ${CMAKE_BINARY_DIR}/imath-install)

ExternalProject_Add(imath_ep
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/imath
    PREFIX ${CMAKE_BINARY_DIR}/imath-ep
    INSTALL_DIR ${IMATH_INSTALL_PREFIX}
    CMAKE_ARGS
        -DCMAKE_INSTALL_PREFIX=${IMATH_INSTALL_PREFIX}
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DBUILD_SHARED_LIBS=OFF
        -DBUILD_TESTING=OFF
        -DIMATH_BUILD_TESTING=OFF
        -DIMATH_INSTALL=ON
        -DIMATH_INSTALL_PKG_CONFIG=OFF
)

ExternalProject_Add(openexr_ep
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/openexr
    PREFIX ${CMAKE_BINARY_DIR}/openexr-ep
    INSTALL_DIR ${CMAKE_BINARY_DIR}/openexr-install
    DEPENDS imath_ep
    CMAKE_ARGS
        -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/openexr-install
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_PREFIX_PATH=${IMATH_INSTALL_PREFIX}
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DBUILD_SHARED_LIBS=OFF
        -DBUILD_TESTING=OFF
        -DOPENEXR_INSTALL=ON
        -DOPENEXR_INSTALL_TOOLS=OFF
        -DOPENEXR_INSTALL_EXAMPLES=OFF
        -DOPENEXR_BUILD_EXAMPLES=OFF
        -DOPENEXR_BUILD_TOOLS=OFF
        -DOPENEXR_BUILD_PYTHON=OFF
        -DOPENEXR_BUILD_TESTING=OFF
        -DOPENEXR_FORCE_INTERNAL_IMATH=OFF
        -DOPENEXR_FORCE_INTERNAL_DEFLATE=ON
        -DOPENEXR_FORCE_INTERNAL_OPENJPH=ON
        -DOPENEXR_INSTALL_PKG_CONFIG=OFF
)

# Stage all built artifacts into the SPM-friendly layout via a custom target
# that runs at install time.
add_custom_target(stage_ocio_openexr ALL
    DEPENDS imath_ep openexr_ep
    COMMAND ${CMAKE_COMMAND} -E make_directory ${OCIO_OPENEXR_VARIANT}/lib
    COMMAND ${CMAKE_COMMAND} -E make_directory ${OCIO_OPENEXR_VARIANT}/include/Imath
    COMMAND ${CMAKE_COMMAND} -E make_directory ${OCIO_OPENEXR_VARIANT}/include/OpenEXR
    # Copy Imath
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${IMATH_INSTALL_PREFIX}/lib ${OCIO_OPENEXR_VARIANT}/lib
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${IMATH_INSTALL_PREFIX}/include/Imath ${OCIO_OPENEXR_VARIANT}/include/Imath
    # Copy OpenEXR
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_BINARY_DIR}/openexr-install/lib ${OCIO_OPENEXR_VARIANT}/lib
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_BINARY_DIR}/openexr-install/include/OpenEXR ${OCIO_OPENEXR_VARIANT}/include/OpenEXR
    COMMENT "Staging Imath + OpenEXR into ${OCIO_OPENEXR_VARIANT}"
)
