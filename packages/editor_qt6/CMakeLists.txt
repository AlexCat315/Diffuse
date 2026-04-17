cmake_minimum_required(VERSION 3.21)
project(GuavaEditorQt6 VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

option(GUAVA_QT6_BUILD_TESTS "Build minimal smoke tests" ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 WebSockets)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(guava_editor_qt6
    src/main.cpp
    src/AppBackend.h
    src/AppBackend.cpp
    src/rpc/EngineRpcClient.h
    src/rpc/EngineRpcClient.cpp
)

qt_add_qml_module(guava_editor_qt6
    URI GuavaEditor
    VERSION 1.0
    QML_FILES
        qml/Main.qml
)

target_link_libraries(guava_editor_qt6
    PRIVATE
        Qt6::Core
        Qt6::Gui
        Qt6::Qml
        Qt6::Quick
        Qt6::QuickControls2
        Qt6::WebSockets
)

target_compile_definitions(guava_editor_qt6 PRIVATE
    $<$<CONFIG:Debug>:QT_STRICT_ITERATORS>
)

if(GUAVA_QT6_BUILD_TESTS)
    include(CTest)
    if(BUILD_TESTING)
        add_test(
            NAME qt6_smoke
            COMMAND guava_editor_qt6 --self-test -platform offscreen
        )
    endif()
endif()
