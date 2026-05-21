# Builds Imath + OpenEXR statically and stages them into a single combined
# static archive inside vendor/ocio_openexr.artifactbundle/<triple>/.
#
# Individual .a files are merged into libOpenEXR_combined.a (or .lib on
# Windows) so SPM can reference them as a single binaryTarget without
# unsafeFlags.

include(ExternalProject)

set(OCIO_OPENEXR_BUNDLE  ${GUAVA_VENDOR_DIR}/ocio_openexr.artifactbundle)
set(OCIO_OPENEXR_VARIANT ${OCIO_OPENEXR_BUNDLE}/${GUAVA_TRIPLE})
set(IMATH_INSTALL_PREFIX ${CMAKE_BINARY_DIR}/imath-install)
set(OPENEXR_EP_SOURCE_DIR ${CMAKE_BINARY_DIR}/openexr-src)
set(OPENEXR_PATCH_SCRIPT ${CMAKE_CURRENT_LIST_DIR}/PatchOpenEXRSetup.cmake)

if(WIN32)
    set(OPENEXR_MSVC_RUNTIME_ARG -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL)
    set(OPENEXR_COMBINED_LIB_NAME "OpenEXR_combined.lib")
else()
    set(OPENEXR_MSVC_RUNTIME_ARG "")
    set(OPENEXR_COMBINED_LIB_NAME "libOpenEXR_combined.a")
endif()

set(OPENEXR_COMBINED_LIB "${OCIO_OPENEXR_VARIANT}/lib/${OPENEXR_COMBINED_LIB_NAME}")

# ── ExternalProject: Imath ────────────────────────────────────────────────────

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
        ${OPENEXR_MSVC_RUNTIME_ARG}
)

# ── ExternalProject: OpenEXR ──────────────────────────────────────────────────

ExternalProject_Add(openexr_ep
    SOURCE_DIR ${OPENEXR_EP_SOURCE_DIR}
    BINARY_DIR ${CMAKE_BINARY_DIR}/openexr-build
    PREFIX ${CMAKE_BINARY_DIR}/openexr-ep
    INSTALL_DIR ${CMAKE_BINARY_DIR}/openexr-install
    DEPENDS imath_ep
    DOWNLOAD_COMMAND
        ${CMAKE_COMMAND} -E rm -rf ${OPENEXR_EP_SOURCE_DIR}
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_SOURCE_DIR}/openexr ${OPENEXR_EP_SOURCE_DIR}
    UPDATE_COMMAND ""
    PATCH_COMMAND
        ${CMAKE_COMMAND}
            -DOPENEXR_SOURCE_DIR=${OPENEXR_EP_SOURCE_DIR}
            -P ${OPENEXR_PATCH_SCRIPT}
    CMAKE_ARGS
        -DCMAKE_INSTALL_PREFIX=${CMAKE_BINARY_DIR}/openexr-install
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_PREFIX_PATH=${IMATH_INSTALL_PREFIX}
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DBUILD_SHARED_LIBS=OFF
        ${OPENEXR_MSVC_RUNTIME_ARG}
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
        -DOPENEXR_INSTALL_COMPAT_HEADERS=OFF
)

# ── Platform-specific combine script ─────────────────────────────────────────
# Written at configure time with fully-expanded paths; invoked by the custom
# target at build time via cmake -P.

set(_combine_script "${CMAKE_BINARY_DIR}/combine_openexr_libs.cmake")

if(APPLE)
    file(WRITE "${_combine_script}"
"execute_process(
    COMMAND /usr/bin/libtool -static
        -o \"${OPENEXR_COMBINED_LIB}\"
        \"${OCIO_OPENEXR_VARIANT}/lib/libIex-3_4.a\"
        \"${OCIO_OPENEXR_VARIANT}/lib/libIlmThread-3_4.a\"
        \"${OCIO_OPENEXR_VARIANT}/lib/libImath-3_2.a\"
        \"${OCIO_OPENEXR_VARIANT}/lib/libOpenEXR-3_4.a\"
        \"${OCIO_OPENEXR_VARIANT}/lib/libOpenEXRCore-3_4.a\"
        \"${OCIO_OPENEXR_VARIANT}/lib/libOpenEXRUtil-3_4.a\"
        \"${OCIO_OPENEXR_VARIANT}/lib/libopenjph.a\"
    COMMAND_ERROR_IS_FATAL ANY)
")
elseif(WIN32)
    file(WRITE "${_combine_script}"
"execute_process(
    COMMAND lib.exe
        \"/OUT:${OPENEXR_COMBINED_LIB}\"
        \"${OCIO_OPENEXR_VARIANT}/lib/OpenEXR-3_4.lib\"
        \"${OCIO_OPENEXR_VARIANT}/lib/OpenEXRUtil-3_4.lib\"
        \"${OCIO_OPENEXR_VARIANT}/lib/OpenEXRCore-3_4.lib\"
        \"${OCIO_OPENEXR_VARIANT}/lib/Iex-3_4.lib\"
        \"${OCIO_OPENEXR_VARIANT}/lib/IlmThread-3_4.lib\"
        \"${OCIO_OPENEXR_VARIANT}/lib/Imath-3_2.lib\"
        \"${OCIO_OPENEXR_VARIANT}/lib/openjph.0.24.lib\"
    COMMAND_ERROR_IS_FATAL ANY)
")
else()  # Linux — GNU ar MRI script
    set(_mri "${CMAKE_BINARY_DIR}/openexr.mri")
    file(WRITE "${_combine_script}"
"file(WRITE \"${_mri}\"
    \"CREATE ${OPENEXR_COMBINED_LIB}\\n\"
    \"ADDLIB ${OCIO_OPENEXR_VARIANT}/lib/libIex-3_4.a\\n\"
    \"ADDLIB ${OCIO_OPENEXR_VARIANT}/lib/libIlmThread-3_4.a\\n\"
    \"ADDLIB ${OCIO_OPENEXR_VARIANT}/lib/libImath-3_2.a\\n\"
    \"ADDLIB ${OCIO_OPENEXR_VARIANT}/lib/libOpenEXR-3_4.a\\n\"
    \"ADDLIB ${OCIO_OPENEXR_VARIANT}/lib/libOpenEXRCore-3_4.a\\n\"
    \"ADDLIB ${OCIO_OPENEXR_VARIANT}/lib/libOpenEXRUtil-3_4.a\\n\"
    \"ADDLIB ${OCIO_OPENEXR_VARIANT}/lib/libopenjph.a\\n\"
    \"SAVE\\n\"
    \"END\\n\")
execute_process(COMMAND ar -M INPUT_FILE \"${_mri}\" COMMAND_ERROR_IS_FATAL ANY)
")
endif()

# ── Stage all artifacts + create combined archive ─────────────────────────────

add_custom_target(stage_ocio_openexr ALL
    DEPENDS imath_ep openexr_ep
    COMMAND ${CMAKE_COMMAND} -E make_directory ${OCIO_OPENEXR_VARIANT}/lib
    COMMAND ${CMAKE_COMMAND} -E make_directory ${OCIO_OPENEXR_VARIANT}/include/Imath
    COMMAND ${CMAKE_COMMAND} -E make_directory ${OCIO_OPENEXR_VARIANT}/include/OpenEXR
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${IMATH_INSTALL_PREFIX}/lib ${OCIO_OPENEXR_VARIANT}/lib
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${IMATH_INSTALL_PREFIX}/include/Imath ${OCIO_OPENEXR_VARIANT}/include/Imath
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_BINARY_DIR}/openexr-install/lib ${OCIO_OPENEXR_VARIANT}/lib
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_BINARY_DIR}/openexr-install/include/OpenEXR ${OCIO_OPENEXR_VARIANT}/include/OpenEXR
    COMMAND ${CMAKE_COMMAND} -P "${_combine_script}"
    COMMENT "Staging and combining Imath + OpenEXR into ${OCIO_OPENEXR_VARIANT}"
)

# ── Write info.json at install time ───────────────────────────────────────────

install(CODE "
file(WRITE \"${OCIO_OPENEXR_BUNDLE}/info.json\"
\"{
  \\\"schemaVersion\\\": \\\"1.0\\\",
  \\\"artifacts\\\": {
    \\\"ocio_openexr\\\": {
      \\\"type\\\": \\\"staticLibrary\\\",
      \\\"version\\\": \\\"3.4.0\\\",
      \\\"variants\\\": [
        {
          \\\"path\\\": \\\"${GUAVA_TRIPLE}/lib/${OPENEXR_COMBINED_LIB_NAME}\\\",
          \\\"supportedTriples\\\": [\\\"${GUAVA_SPM_TRIPLE}\\\"],
          \\\"staticLibraryMetadata\\\": {
            \\\"headerPaths\\\": [
              \\\"${GUAVA_TRIPLE}/include\\\",
              \\\"${GUAVA_TRIPLE}/include/OpenEXR\\\",
              \\\"${GUAVA_TRIPLE}/include/Imath\\\"
            ]
          }
        }
      ]
    }
  }
}
\")
")
