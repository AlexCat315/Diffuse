cmake_minimum_required(VERSION 3.20)
if(POLICY CMP0177)
    cmake_policy(SET CMP0177 NEW)
endif()
project(cove-third-party LANGUAGES C CXX)

# Engine builds its own native dependencies against an installed Cove SDK.
# Keep its build helpers here; released SDKs do not ship native source tooling.
include("${CMAKE_CURRENT_LIST_DIR}/cmake/NativePlatform.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/cmake/ArtifactBundleManifest.cmake")

message(STATUS "Cove third-party target triple: ${COVE_TRIPLE} (SPM: ${COVE_SPM_TRIPLE})")

set(COVE_VENDOR_DIR ${CMAKE_SOURCE_DIR}/../vendor CACHE PATH "Native artifact output directory")

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
