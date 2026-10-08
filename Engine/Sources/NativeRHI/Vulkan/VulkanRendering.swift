#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders

struct VulkanRenderingCommands {
    let begin: CVulkanHeaders.PFN_vkCmdBeginRendering
    let end: CVulkanHeaders.PFN_vkCmdEndRendering

    init(_ resolve: VulkanResolver) {
        begin = vkFunction(resolve, "vkCmdBeginRendering")
        end = vkFunction(resolve, "vkCmdEndRendering")
    }
}

struct VulkanFeatureSupport {
    var dynamicRendering = false
    var nonSolidFill = false
    var accelerationStructures = false
    var rayQuery = false
    var mesh = false
    var task = false
}
#endif
