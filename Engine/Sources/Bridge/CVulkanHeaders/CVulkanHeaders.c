// CVulkanHeaders — bridge compilation unit.
//
// The Vulkan headers are vendored in the linked `vulkan_loader` artifact; this
// translation unit exists so SwiftPM builds the Clang target with the bundle's
// header search paths and re-exports the Vulkan C API through the umbrella.
// It contains no logic.
#include "CVulkanHeaders.h"
