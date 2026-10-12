#if (os(Windows) || os(Linux) || os(Android)) && canImport(CVulkanHeaders)
import CVulkanHeaders

/// One subpass expresses the same attachment contract on desktop and mobile.
/// Core render passes allow Vulkan 1.1 drivers without dynamic rendering.
struct VulkanRenderingCommands {
    let createPass: CVulkanHeaders.PFN_vkCreateRenderPass
    let destroyPass: CVulkanHeaders.PFN_vkDestroyRenderPass
    let createFramebuffer: CVulkanHeaders.PFN_vkCreateFramebuffer
    let destroyFramebuffer: CVulkanHeaders.PFN_vkDestroyFramebuffer
    let begin: CVulkanHeaders.PFN_vkCmdBeginRenderPass
    let end: CVulkanHeaders.PFN_vkCmdEndRenderPass

    init(_ resolve: VulkanResolver) {
        createPass = vkFunction(resolve, "vkCreateRenderPass")
        destroyPass = vkFunction(resolve, "vkDestroyRenderPass")
        createFramebuffer = vkFunction(resolve, "vkCreateFramebuffer")
        destroyFramebuffer = vkFunction(resolve, "vkDestroyFramebuffer")
        begin = vkFunction(resolve, "vkCmdBeginRenderPass")
        end = vkFunction(resolve, "vkCmdEndRenderPass")
    }
}

struct VulkanFeatureSupport {
    var spirvVersion: UInt32 = 0x00010300
    var maintenance4 = false
    var nonSolidFill = false
    var accelerationStructures = false
    var rayQuery = false
    var mesh = false
    var task = false
}

/// Owns native attachment objects until the submission fence has completed.
/// Failed encoding releases them immediately; successful encoding transfers
/// ownership to the fence waiter, including submissions on dedicated queues.
final class VulkanRenderPassObjects {
    let context: VulkanContext
    private var passes: [VkRenderPass] = []
    private var framebuffers: [VkFramebuffer] = []

    init(context: VulkanContext) { self.context = context }

    func makePass(attachments: [VkAttachmentDescription], colors: [VkAttachmentReference],
                  resolves: [VkAttachmentReference] = [], depth: VkAttachmentReference? = nil) throws -> VkRenderPass {
        let arena = VulkanScratch()
        var subpass = VkSubpassDescription()
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
        subpass.colorAttachmentCount = UInt32(colors.count)
        subpass.pColorAttachments = arena.store(colors)
        subpass.pResolveAttachments = arena.store(resolves)
        if let depth { subpass.pDepthStencilAttachment = UnsafePointer(arena.make(depth)) }
        var info = VkRenderPassCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
        info.attachmentCount = UInt32(attachments.count)
        info.pAttachments = arena.store(attachments)
        info.subpassCount = 1
        info.pSubpasses = UnsafePointer(arena.make(subpass))
        var pass: VkRenderPass?
        let result = withExtendedLifetime(arena) { context.rendering.createPass(context.device, &info, nil, &pass) }
        guard result == VK_SUCCESS, let pass else { throw RHIError.invalidArgument("vkCreateRenderPass failed: \(result)") }
        passes.append(pass)
        return pass
    }

    func pipelinePass(_ descriptor: GraphicsPipelineDescriptor) throws -> VkRenderPass {
        let colors = descriptor.colorAttachments.enumerated().map {
            VkAttachmentReference(attachment: UInt32($0.offset), layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        }
        var attachments = try descriptor.colorAttachments.map {
            try attachment(format: VulkanFormats.vkFormat($0.format), samples: descriptor.sampleCount,
                           layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        }
        var depth: VkAttachmentReference?
        if let format = descriptor.depthFormat {
            depth = VkAttachmentReference(attachment: UInt32(attachments.count), layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
            attachments.append(try attachment(format: VulkanFormats.vkFormat(format), samples: descriptor.sampleCount,
                                              layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL))
        }
        // Resolve references are ignored for single-subpass compatibility, so
        // the same pipeline works with and without explicit color resolves.
        return try makePass(attachments: attachments, colors: colors, depth: depth)
    }

    func begin(cmd: VkCommandBuffer, rendering: VkRenderingInfo, signature: RenderPassSignature<VkFormat>) throws {
        var attachments: [VkAttachmentDescription] = []
        var views: [VkImageView?] = []
        var clears: [VkClearValue] = []
        var colors: [VkAttachmentReference] = []
        var resolves: [VkAttachmentReference] = []
        func append(_ target: VkRenderingAttachmentInfo, format: VkFormat, samples: Int) throws -> VkAttachmentReference {
            var value = try attachment(format: format, samples: samples, layout: target.imageLayout)
            value.loadOp = target.loadOp; value.storeOp = target.storeOp
            let reference = VkAttachmentReference(attachment: UInt32(attachments.count), layout: target.imageLayout)
            attachments.append(value); views.append(target.imageView); clears.append(target.clearValue)
            return reference
        }
        for index in 0..<Int(rendering.colorAttachmentCount) {
            let target = rendering.pColorAttachments![index]
            colors.append(try append(target, format: signature.colors[index], samples: signature.sampleCount))
            if target.resolveMode != VK_RESOLVE_MODE_NONE {
                var resolve = VkRenderingAttachmentInfo()
                resolve.imageView = target.resolveImageView; resolve.imageLayout = target.resolveImageLayout
                resolve.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; resolve.storeOp = VK_ATTACHMENT_STORE_OP_STORE
                resolves.append(try append(resolve, format: signature.colors[index], samples: 1))
            } else {
                resolves.append(VkAttachmentReference(attachment: UInt32.max, layout: VK_IMAGE_LAYOUT_UNDEFINED))
            }
        }
        var depth: VkAttachmentReference?
        if let target = rendering.pDepthAttachment, let format = signature.depth {
            depth = try append(target.pointee, format: format, samples: signature.sampleCount)
        }
        let pass = try makePass(attachments: attachments, colors: colors, resolves: resolves, depth: depth)
        let arena = VulkanScratch()
        var framebufferInfo = VkFramebufferCreateInfo()
        framebufferInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
        framebufferInfo.renderPass = pass
        framebufferInfo.attachmentCount = UInt32(views.count)
        framebufferInfo.pAttachments = arena.store(views)
        framebufferInfo.width = rendering.renderArea.extent.width
        framebufferInfo.height = rendering.renderArea.extent.height
        framebufferInfo.layers = 1
        var framebuffer: VkFramebuffer?
        let result = withExtendedLifetime(arena) { context.rendering.createFramebuffer(context.device, &framebufferInfo, nil, &framebuffer) }
        guard result == VK_SUCCESS, let framebuffer else { throw RHIError.invalidArgument("vkCreateFramebuffer failed: \(result)") }
        framebuffers.append(framebuffer)
        var begin = VkRenderPassBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
        begin.renderPass = pass; begin.framebuffer = framebuffer; begin.renderArea = rendering.renderArea
        begin.clearValueCount = UInt32(clears.count); begin.pClearValues = arena.store(clears)
        withExtendedLifetime(arena) { context.rendering.begin(cmd, &begin, VK_SUBPASS_CONTENTS_INLINE) }
    }

    private func attachment(format: VkFormat, samples: Int, layout: VkImageLayout) throws -> VkAttachmentDescription {
        var value = VkAttachmentDescription()
        value.format = format; value.samples = try VulkanFormats.vkSampleCount(samples)
        value.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; value.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
        value.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; value.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
        value.initialLayout = layout; value.finalLayout = layout
        return value
    }

    deinit {
        for framebuffer in framebuffers { context.rendering.destroyFramebuffer(context.device, framebuffer, nil) }
        for pass in passes { context.rendering.destroyPass(context.device, pass, nil) }
    }
}
#endif
