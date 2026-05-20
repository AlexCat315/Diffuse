# Builds JoltPhysics (libJolt.a) via ExternalProject and stages into
# Engine/vendor/Jolt.artifactbundle/<triple>/.

include(ExternalProject)

set(JOLT_BUNDLE ${GUAVA_VENDOR_DIR}/Jolt.artifactbundle)
set(JOLT_VARIANT ${JOLT_BUNDLE}/${GUAVA_TRIPLE})
set(JOLT_INSTALL_PREFIX ${CMAKE_BINARY_DIR}/jolt-install)

# Architecture-specific SIMD switches. Jolt defaults x86 SSE/AVX flags ON;
# on Apple Silicon those must be off (clang errors otherwise).
if(GUAVA_TRIPLE STREQUAL "macos-arm64" OR GUAVA_TRIPLE STREQUAL "linux-aarch64")
    set(JOLT_SIMD_FLAGS
        -DUSE_SSE4_1=OFF -DUSE_SSE4_2=OFF
        -DUSE_AVX=OFF -DUSE_AVX2=OFF -DUSE_AVX512=OFF
        -DUSE_LZCNT=OFF -DUSE_TZCNT=OFF
        -DUSE_F16C=OFF -DUSE_FMADD=OFF
    )
else()
    set(JOLT_SIMD_FLAGS
        -DUSE_SSE4_1=ON -DUSE_SSE4_2=ON
        -DUSE_AVX=ON -DUSE_AVX2=ON
        -DUSE_LZCNT=ON -DUSE_TZCNT=ON
        -DUSE_F16C=ON -DUSE_FMADD=ON
    )
endif()

if(WIN32)
    set(JOLT_MSVC_RUNTIME_ARG
        -DUSE_STATIC_MSVC_RUNTIME_LIBRARY=OFF
        -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL)
else()
    set(JOLT_MSVC_RUNTIME_ARG "")
endif()

ExternalProject_Add(jolt_ep
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/jolt/Build
    PREFIX ${CMAKE_BINARY_DIR}/jolt-ep
    INSTALL_DIR ${JOLT_INSTALL_PREFIX}
    CMAKE_ARGS
        -DCMAKE_INSTALL_PREFIX=${JOLT_INSTALL_PREFIX}
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DBUILD_SHARED_LIBS=OFF
        ${JOLT_MSVC_RUNTIME_ARG}
        # Build only the library — no tests/samples/viewer
        -DTARGET_UNIT_TESTS=OFF
        -DTARGET_HELLO_WORLD=OFF
        -DTARGET_PERFORMANCE_TEST=OFF
        -DTARGET_SAMPLES=OFF
        -DTARGET_VIEWER=OFF
        # Library config
        -DENABLE_INSTALL=ON
        -DOVERRIDE_CXX_FLAGS=OFF
        -DCPP_EXCEPTIONS_ENABLED=OFF
        -DCPP_RTTI_ENABLED=OFF
        -DDEBUG_RENDERER_IN_DEBUG_AND_RELEASE=OFF
        -DFLOATING_POINT_EXCEPTIONS_ENABLED=OFF
        -DINTERPROCEDURAL_OPTIMIZATION=OFF
        -DENABLE_ALL_WARNINGS=OFF
        ${JOLT_SIMD_FLAGS}
)

if(WIN32)
    set(JOLT_LIB_FILENAME "Jolt.lib")
else()
    set(JOLT_LIB_FILENAME "libJolt.a")
endif()

add_custom_target(stage_jolt ALL
    DEPENDS jolt_ep
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${JOLT_VARIANT}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${JOLT_VARIANT}/lib
    COMMAND ${CMAKE_COMMAND} -E make_directory ${JOLT_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E copy
        ${JOLT_INSTALL_PREFIX}/lib/${JOLT_LIB_FILENAME}
        ${JOLT_VARIANT}/lib/${JOLT_LIB_FILENAME}
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${JOLT_INSTALL_PREFIX}/include ${JOLT_VARIANT}/include
    COMMENT "Staging Jolt into ${JOLT_VARIANT}"
)

# Generate artifactbundle info.json
install(CODE "
    file(WRITE ${JOLT_BUNDLE}/info.json
\"{
  \\\"schemaVersion\\\": \\\"1.0\\\",
  \\\"artifacts\\\": {
    \\\"Jolt\\\": {
      \\\"type\\\": \\\"staticLibrary\\\",
      \\\"version\\\": \\\"5.5.0\\\",
      \\\"variants\\\": [
        {
          \\\"path\\\": \\\"${GUAVA_TRIPLE}/lib/${JOLT_LIB_FILENAME}\\\",
          \\\"supportedTriples\\\": [\\\"${GUAVA_SPM_TRIPLE}\\\"],
          \\\"staticLibraryMetadata\\\": {
            \\\"headerPaths\\\": [\\\"${GUAVA_TRIPLE}/include\\\"]
          }
        }
      ]
    }
  }
}
\")
")
