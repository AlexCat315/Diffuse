cmake_minimum_required(VERSION 3.20)
if(POLICY CMP0177)
    cmake_policy(SET CMP0177 NEW)
endif()
project(cove-third-party LANGUAGES C CXX)

set(COVE_SDK_ROOT "$ENV{COVE_SDK_ROOT}" CACHE PATH "Cove SDK checkout")
if(NOT COVE_SDK_ROOT)
    set(COVE_SDK_ROOT "${CMAKE_SOURCE_DIR}/../../CoveUI")
endif()
include("${COVE_SDK_ROOT}/cmake/NativePlatform.cmake")
include("${COVE_SDK_ROOT}/cmake/ArtifactBundleManifest.cmake")

message(STATUS "Cove third-party target triple: ${COVE_TRIPLE} (SPM: ${COVE_SPM_TRIPLE})")

set(COVE_VENDOR_DIR ${CMAKE_SOURCE_DIR}/../vendor CACHE PATH "Native artifact output directory")

# ============================================================================
# Wasmtime Component runtime (pinned static C API artifacts and iOS Pulley source build)
# ============================================================================
option(COVE_STAGE_WASMTIME "Stage the plugin runtime" ON)
if(COVE_STAGE_WASMTIME)
    include(${CMAKE_SOURCE_DIR}/cmake/FetchWasmtime.cmake)
endif()

# ============================================================================
# Static-only, minimal-dependency build profile
# ============================================================================
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON CACHE BOOL "" FORCE)

# ============================================================================
# SDL3
# ============================================================================

# ============================================================================
# OpenEXR + Imath
# ============================================================================
option(COVE_BUILD_OPENEXR "Build the desktop EXR import/export stack" ON)
if(COVE_BUILD_OPENEXR)
    include(${CMAKE_SOURCE_DIR}/cmake/BuildOpenEXRStack.cmake)
endif()

# ============================================================================
# Unified image decoding dependencies (SVG/WebP)
# ============================================================================
