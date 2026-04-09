cmake_minimum_required(VERSION 3.21)
project(Citron LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)

# ── CEF paths ────────────────────────────────────────────────────────────
set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/cef")
set(CEF_WRAPPER_LIB "${CEF_ROOT}/build/libcef_dll_wrapper/libcef_dll_wrapper.a")
set(CEF_FRAMEWORK "${CEF_ROOT}/Release/Chromium Embedded Framework.framework")

# ── Sources ──────────────────────────────────────────────────────────────
set(CITRON_SOURCES
    src/main.mm
    src/citron_shell.mm
)

add_executable(Citron MACOSX_BUNDLE ${CITRON_SOURCES})

# Enable ARC, suppress deprecation warnings, disable RTTI/exceptions (match CEF).
target_compile_options(Citron PRIVATE
    -fobjc-arc
    -Wno-deprecated-declarations
    -fno-rtti
    -fno-exceptions
)

target_include_directories(Citron PRIVATE
    include
    "${CEF_ROOT}"
    "${CEF_ROOT}/include"
)

# ── Link CEF ─────────────────────────────────────────────────────────────
target_link_libraries(Citron PRIVATE
    "${CEF_WRAPPER_LIB}"
    "${CEF_FRAMEWORK}/Chromium Embedded Framework"
    "-framework AppKit"
    "-framework Metal"
    "-framework MetalKit"
    "-framework QuartzCore"
    "-framework IOSurface"
    "-framework CoreVideo"
)

# ── App Bundle Info ──────────────────────────────────────────────────────
set_target_properties(Citron PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_BUNDLE_NAME "Citron"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.guava.citron"
    MACOSX_BUNDLE_BUNDLE_VERSION "0.1.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1.0"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
)

# ── Copy CEF framework into app bundle ───────────────────────────────────
add_custom_command(TARGET Citron POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
        "$<TARGET_BUNDLE_DIR:Citron>/Contents/Frameworks"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CEF_FRAMEWORK}"
        "$<TARGET_BUNDLE_DIR:Citron>/Contents/Frameworks/Chromium Embedded Framework.framework"
    COMMENT "Copying CEF framework into app bundle..."
)
