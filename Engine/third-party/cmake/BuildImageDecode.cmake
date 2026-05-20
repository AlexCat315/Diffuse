# Builds SVG/WebP native decoding dependencies and stages them into SPM
# artifact bundles. PNG/JPEG are decoded by stb_image inside CImageDecodeBridge.

include(FetchContent)

set(LUNASVG_VERSION "v3.5.0")
set(LIBWEBP_VERSION "v1.6.0")

set(LUNASVG_BUNDLE ${GUAVA_VENDOR_DIR}/lunasvg.artifactbundle)
set(PLUTOVG_BUNDLE ${GUAVA_VENDOR_DIR}/plutovg.artifactbundle)
set(WEBP_BUNDLE ${GUAVA_VENDOR_DIR}/webp.artifactbundle)
set(SHARPYUV_BUNDLE ${GUAVA_VENDOR_DIR}/sharpyuv.artifactbundle)

set(LUNASVG_VARIANT ${LUNASVG_BUNDLE}/${GUAVA_TRIPLE})
set(PLUTOVG_VARIANT ${PLUTOVG_BUNDLE}/${GUAVA_TRIPLE})
set(WEBP_VARIANT ${WEBP_BUNDLE}/${GUAVA_TRIPLE})
set(SHARPYUV_VARIANT ${SHARPYUV_BUNDLE}/${GUAVA_TRIPLE})

set(LUNASVG_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LUNASVG_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(USE_SYSTEM_PLUTOVG OFF CACHE BOOL "" FORCE)

set(WEBP_BUILD_ANIM_UTILS OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_CWEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_DWEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_GIF2WEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_IMG2WEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_VWEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBPINFO OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBPMUX OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_EXTRAS OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_LIBWEBPMUX OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBP_JS OFF CACHE BOOL "" FORCE)
set(WEBP_ENABLE_SIMD ON CACHE BOOL "" FORCE)

if(WIN32)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL" CACHE STRING "" FORCE)
endif()

FetchContent_Declare(
    lunasvg
    GIT_REPOSITORY https://github.com/sammycage/lunasvg.git
    GIT_TAG ${LUNASVG_VERSION}
    GIT_SHALLOW TRUE
)
FetchContent_Declare(
    libwebp
    GIT_REPOSITORY https://chromium.googlesource.com/webm/libwebp
    GIT_TAG ${LIBWEBP_VERSION}
    GIT_SHALLOW TRUE
)

FetchContent_MakeAvailable(lunasvg libwebp)

if(WIN32)
    set(LUNASVG_LIB_FILENAME "lunasvg.lib")
    set(PLUTOVG_LIB_FILENAME "plutovg.lib")
    set(WEBP_LIB_FILENAME "webp.lib")
    set(SHARPYUV_LIB_FILENAME "sharpyuv.lib")
else()
    set(LUNASVG_LIB_FILENAME "liblunasvg.a")
    set(PLUTOVG_LIB_FILENAME "libplutovg.a")
    set(WEBP_LIB_FILENAME "libwebp.a")
    set(SHARPYUV_LIB_FILENAME "libsharpyuv.a")
endif()

add_custom_target(stage_image_decode
    DEPENDS lunasvg webp sharpyuv
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${LUNASVG_VARIANT} ${PLUTOVG_VARIANT} ${WEBP_VARIANT} ${SHARPYUV_VARIANT}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${LUNASVG_VARIANT}/lib ${LUNASVG_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E make_directory ${PLUTOVG_VARIANT}/lib ${PLUTOVG_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E make_directory ${WEBP_VARIANT}/lib ${WEBP_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E make_directory ${SHARPYUV_VARIANT}/lib ${SHARPYUV_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:lunasvg> ${LUNASVG_VARIANT}/lib/${LUNASVG_LIB_FILENAME}
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:plutovg> ${PLUTOVG_VARIANT}/lib/${PLUTOVG_LIB_FILENAME}
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:webp> ${WEBP_VARIANT}/lib/${WEBP_LIB_FILENAME}
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:sharpyuv> ${SHARPYUV_VARIANT}/lib/${SHARPYUV_LIB_FILENAME}
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${lunasvg_SOURCE_DIR}/include ${LUNASVG_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${lunasvg_SOURCE_DIR}/plutovg/include ${PLUTOVG_VARIANT}/include
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${libwebp_SOURCE_DIR}/src/webp ${WEBP_VARIANT}/include/webp
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${libwebp_SOURCE_DIR}/sharpyuv ${SHARPYUV_VARIANT}/include/sharpyuv
    COMMENT "Staging image decode libraries into Engine/vendor"
)

function(write_static_artifact_bundle bundle artifact version triple spm_triple lib_filename)
    file(MAKE_DIRECTORY ${bundle})
    file(WRITE ${bundle}/info.json
"{
  \"schemaVersion\": \"1.0\",
  \"artifacts\": {
    \"${artifact}\": {
      \"type\": \"staticLibrary\",
      \"version\": \"${version}\",
      \"variants\": [
        {
          \"path\": \"${triple}/lib/${lib_filename}\",
          \"supportedTriples\": [\"${spm_triple}\"],
          \"staticLibraryMetadata\": {
            \"headerPaths\": [\"${triple}/include\"]
          }
        }
      ]
    }
  }
}
")
endfunction()

write_static_artifact_bundle(${LUNASVG_BUNDLE} "lunasvg" "3.5.0" ${GUAVA_TRIPLE} ${GUAVA_SPM_TRIPLE} ${LUNASVG_LIB_FILENAME})
write_static_artifact_bundle(${PLUTOVG_BUNDLE} "plutovg" "1.0.0" ${GUAVA_TRIPLE} ${GUAVA_SPM_TRIPLE} ${PLUTOVG_LIB_FILENAME})
write_static_artifact_bundle(${WEBP_BUNDLE} "webp" "1.6.0" ${GUAVA_TRIPLE} ${GUAVA_SPM_TRIPLE} ${WEBP_LIB_FILENAME})
write_static_artifact_bundle(${SHARPYUV_BUNDLE} "sharpyuv" "1.6.0" ${GUAVA_TRIPLE} ${GUAVA_SPM_TRIPLE} ${SHARPYUV_LIB_FILENAME})
