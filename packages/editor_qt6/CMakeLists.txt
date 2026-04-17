cmake_minimum_required(VERSION 3.21)
project(GuavaEditorQt6 VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

option(GUAVA_QT6_BUILD_TESTS "Build minimal smoke tests" ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets)

add_executable(guava_editor_qt6
    src/main.cpp
    src/MainWindow.h
    src/MainWindow.cpp
)

target_link_libraries(guava_editor_qt6
    PRIVATE
        Qt6::Core
        Qt6::Gui
        Qt6::Widgets
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
