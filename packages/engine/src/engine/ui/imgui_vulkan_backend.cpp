// ---------------------------------------------------------------------------
// ImGui Vulkan backend wrapper — mirrors imgui_metal_backend.mm for Vulkan.
//
// Implements guava_imgui_vulkan_backend_{init,render,shutdown} using
// the imgui_impl_vulkan backend + Vulkan handle getters from vk_bridge.
// ---------------------------------------------------------------------------

#include "imgui_bridge.h"
#include "backends/imgui_impl_vulkan.h"
#include "imgui.h"

#include <vulkan/vulkan.h>
#include "../rhi/vulkan/vk_bridge.h"

extern "C" bool guava_imgui_vulkan_backend_init(void *vk_bridge_ctx) {
    if (!vk_bridge_ctx)
        return false;

    ImGui_ImplVulkan_InitInfo init_info = {};
    init_info.ApiVersion     = VK_API_VERSION_1_3;
    init_info.Instance       = (VkInstance)guava_vk_rhi_get_instance(vk_bridge_ctx);
    init_info.PhysicalDevice = (VkPhysicalDevice)guava_vk_rhi_get_physical_device(vk_bridge_ctx);
    init_info.Device         = (VkDevice)guava_vk_rhi_get_vk_device(vk_bridge_ctx);
    init_info.QueueFamily    = guava_vk_rhi_get_graphics_queue_family(vk_bridge_ctx);
    init_info.Queue          = (VkQueue)guava_vk_rhi_get_graphics_queue(vk_bridge_ctx);
    init_info.DescriptorPoolSize = 100; // Let ImGui backend create its own pool
    init_info.MinImageCount  = 2;
    init_info.ImageCount     = guava_vk_rhi_get_swapchain_image_count(vk_bridge_ctx);
    if (init_info.ImageCount < 2)
        init_info.ImageCount = 2;

    VkRenderPass rp = (VkRenderPass)guava_vk_rhi_get_swapchain_render_pass(vk_bridge_ctx);
    init_info.PipelineInfoMain.RenderPass = rp;

    return ImGui_ImplVulkan_Init(&init_info);
}

extern "C" void guava_imgui_vulkan_backend_shutdown(void) {
    ImGui_ImplVulkan_Shutdown();
}

extern "C" bool guava_imgui_vulkan_backend_render(void *vk_command_buffer) {
    if (!vk_command_buffer)
        return false;

    if (ImGui::GetCurrentContext() == nullptr)
        return false;

    ImDrawData *draw_data = ImGui::GetDrawData();
    if (!draw_data || draw_data->DisplaySize.x <= 0.0f || draw_data->DisplaySize.y <= 0.0f)
        return false;

    ImGui_ImplVulkan_NewFrame();
    ImGui_ImplVulkan_RenderDrawData(draw_data, (VkCommandBuffer)vk_command_buffer);
    return true;
}
