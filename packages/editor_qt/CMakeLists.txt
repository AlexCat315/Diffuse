cmake_minimum_required(VERSION 3.25)
project(GuavaEditor VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# Generate compile_commands.json for clangd
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ── Qt 6 ──────────────────────────────────────────────────────────────────
find_package(Qt6 REQUIRED COMPONENTS
    Core
    Gui
    Quick
    Qml
    QuickControls2
    Widgets
    WebSockets
    Network
    Svg
)

# ── Sources ───────────────────────────────────────────────────────────────
set(SOURCES
    src/main_qml.cpp
    src/app/MainWindow.h
    src/app/MainWindow.cpp
    src/app/EngineProcess.h
    src/app/EngineProcess.cpp
    src/engine/EngineClient.h
    src/engine/EngineClient.cpp
    src/panels/ViewportWidget.h
    src/panels/ViewportWidget.mm
    src/panels/MetalViewportItem.h
    src/panels/MetalViewportItem.cpp
    src/panels/SceneTreeWidget.h
    src/panels/SceneTreeWidget.cpp
    src/panels/InspectorWidget.h
    src/panels/InspectorWidget.cpp
    src/theme/Theme.h
    src/theme/Theme.cpp
    src/util/MacOS.h
    src/util/MacOS.mm
    src/util/IconProvider.h
    src/util/IconProvider.cpp
    src/util/Translator.h
    src/util/Translator.cpp
    src/util/TranslatorQML.h
    src/util/TranslatorQML.cpp
    src/util/SceneNode.h
    src/util/SceneNode.cpp
    src/util/SceneModel.h
    src/util/SceneModel.cpp
)

# ── Resources ─────────────────────────────────────────────────────────────
set(RESOURCES
    resources/resources.qrc
)

# ── Executable ────────────────────────────────────────────────────────────
if(APPLE)
    set(MACOSX_BUNDLE_ICON_FILE guava.icns)
    add_executable(${PROJECT_NAME} MACOSX_BUNDLE ${SOURCES} ${RESOURCES})
    set_target_properties(${PROJECT_NAME} PROPERTIES
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.guava.editor"
        MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
        MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    )
else()
    add_executable(${PROJECT_NAME} ${SOURCES} ${RESOURCES})
endif()

target_include_directories(${PROJECT_NAME} PRIVATE src)

target_link_libraries(${PROJECT_NAME} PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::Qml
    Qt6::QuickControls2
    Qt6::Widgets
    Qt6::WebSockets
    Qt6::Network
    Qt6::Svg
)

# ── macOS frameworks ──────────────────────────────────────────────────────
if(APPLE)
    target_link_libraries(${PROJECT_NAME} PRIVATE
        "-framework AppKit"
        "-framework Metal"
        "-framework MetalKit"
        "-framework QuartzCore"
        "-framework IOSurface"
        "-framework CoreVideo"
    )
endif()

# ── Install ───────────────────────────────────────────────────────────────
install(TARGETS ${PROJECT_NAME}
    BUNDLE DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
