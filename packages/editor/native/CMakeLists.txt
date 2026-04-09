cmake_minimum_required(VERSION 3.15)
cmake_policy(SET CMP0091 NEW)
cmake_policy(SET CMP0042 NEW)

project(iosurface_view)

add_definitions(-DNAPI_VERSION=8)
add_definitions(-DNAPI_DISABLE_CPP_EXCEPTIONS)

include_directories(${CMAKE_JS_INC})

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# node-addon-api headers
execute_process(
  COMMAND node -p "require('node-addon-api').include_dir"
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  OUTPUT_VARIABLE NODE_ADDON_API_DIR
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
include_directories(${NODE_ADDON_API_DIR})

# Platform-specific sources and libraries
if(APPLE)
  add_library(${PROJECT_NAME} SHARED src/iosurface_view.mm)
  set_target_properties(${PROJECT_NAME} PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  target_link_libraries(${PROJECT_NAME} PRIVATE
    "-framework IOSurface"
    "-framework AppKit"
    "-framework QuartzCore"
    "-framework CoreVideo"
    ${CMAKE_JS_LIB}
  )
  set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0")
elseif(UNIX)
  add_library(${PROJECT_NAME} SHARED src/shm_view.cpp)
  target_link_libraries(${PROJECT_NAME} PRIVATE rt ${CMAKE_JS_LIB})
endif()

set_target_properties(${PROJECT_NAME} PROPERTIES
  PREFIX ""
  SUFFIX ".node"
)
