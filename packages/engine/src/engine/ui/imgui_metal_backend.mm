#include "imgui_bridge.h"

#include "backends/imgui_impl_metal.h"
#include "imgui.h"
#include "../rhi/metal/metal_rhi_bridge.h"

extern "C" bool guava_imgui_metal_backend_init(void *metal_bridge_ctx) {
  if (metal_bridge_ctx == nullptr) {
    return false;
  }

  id<MTLDevice> device = (__bridge id<MTLDevice>)guava_metal_rhi_get_mtl_device(metal_bridge_ctx);
  if (!device) {
    return false;
  }

  return ImGui_ImplMetal_Init(device);
}

extern "C" void guava_imgui_metal_backend_shutdown(void) {
  ImGui_ImplMetal_Shutdown();
}

extern "C" bool guava_imgui_metal_backend_render(void *command_buffer,
                                                  void *render_encoder,
                                                  void *render_pass_desc) {
  if (command_buffer == nullptr || render_encoder == nullptr || render_pass_desc == nullptr) {
    return false;
  }

  if (ImGui::GetCurrentContext() == nullptr) {
    return false;
  }

  ImDrawData *draw_data = ImGui::GetDrawData();
  if (draw_data == nullptr || draw_data->DisplaySize.x <= 0.0f || draw_data->DisplaySize.y <= 0.0f) {
    return false;
  }

  MTLRenderPassDescriptor *rpd = (__bridge MTLRenderPassDescriptor *)render_pass_desc;
  id<MTLCommandBuffer> mtl_cmd = (__bridge id<MTLCommandBuffer>)command_buffer;
  id<MTLRenderCommandEncoder> mtl_enc = (__bridge id<MTLRenderCommandEncoder>)render_encoder;

  ImGui_ImplMetal_NewFrame(rpd);
  ImGui_ImplMetal_RenderDrawData(draw_data, mtl_cmd, mtl_enc);
  return true;
}
