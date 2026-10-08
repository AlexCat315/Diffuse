// CVulkanHeaders — umbrella header that re-exports the vendored Vulkan headers.
//
// This target contains no logic: it gives Swift a single module
// (`CVulkanHeaders`) through which the Vulkan C API is visible. The Vulkan
// headers and the dynamic loader (libvulkan) are vendored in the
// `VulkanLoader.xcframework` that this target links at build time. The
// driver (an ICD such as MoltenVK) is discovered by the loader at runtime, so
// the backend throws cleanly when no physical device is present.
#pragma once

#include <vulkan/vulkan.h>
