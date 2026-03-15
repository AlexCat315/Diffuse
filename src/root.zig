//! Guava Engine: a Zig runtime for games, film/animation, and tooling.
const std = @import("std");

pub const core = struct {
    pub const Application = @import("engine/core/application.zig").Application;
    pub const ApplicationConfig = @import("engine/core/application.zig").ApplicationConfig;
    pub const Layer = @import("engine/core/layer.zig").Layer;
    pub const LayerContext = @import("engine/core/layer.zig").LayerContext;
    pub const Platform = @import("engine/core/platform.zig").Platform;
    pub const detectPlatform = @import("engine/core/platform.zig").detect;
    pub const platformName = @import("engine/core/platform.zig").name;
};

pub const platform = struct {
    pub const Window = @import("engine/platform/window.zig").Window;
    pub const WindowConfig = @import("engine/platform/window.zig").WindowConfig;
    pub const WindowEvent = @import("engine/platform/window.zig").Event;
    pub const WindowEventKind = @import("engine/platform/window.zig").EventKind;
};

pub const rhi = struct {
    pub const Device = @import("engine/rhi/device.zig").RhiDevice;
    pub const Buffer = @import("engine/rhi/device.zig").Buffer;
    pub const BindGroup = @import("engine/rhi/device.zig").BindGroup;
    pub const Frame = @import("engine/rhi/device.zig").Frame;
    pub const GraphicsPipeline = @import("engine/rhi/device.zig").GraphicsPipeline;
    pub const GraphicsPipelineDesc = @import("engine/rhi/device.zig").GraphicsPipelineDesc;
    pub const Sampler = @import("engine/rhi/device.zig").Sampler;
    pub const SamplerDesc = @import("engine/rhi/device.zig").SamplerDesc;
    pub const ShaderModule = @import("engine/rhi/device.zig").ShaderModule;
    pub const ShaderModuleDesc = @import("engine/rhi/device.zig").ShaderModuleDesc;
    pub const Texture = @import("engine/rhi/device.zig").Texture;
    pub const TextureSamplerBinding = @import("engine/rhi/device.zig").TextureSamplerBinding;
    pub const TransferBuffer = @import("engine/rhi/device.zig").TransferBuffer;
    pub const BackendSelectionPolicy = @import("engine/rhi/types.zig").BackendSelectionPolicy;
    pub const CompareOp = @import("engine/rhi/types.zig").CompareOp;
    pub const CullMode = @import("engine/rhi/types.zig").CullMode;
    pub const FillMode = @import("engine/rhi/types.zig").FillMode;
    pub const FrontFace = @import("engine/rhi/types.zig").FrontFace;
    pub const GraphicsAPI = @import("engine/rhi/types.zig").GraphicsAPI;
    pub const DeviceConfig = @import("engine/rhi/types.zig").DeviceConfig;
    pub const BufferUsage = @import("engine/rhi/types.zig").BufferUsage;
    pub const IndexElementSize = @import("engine/rhi/types.zig").IndexElementSize;
    pub const PrimitiveType = @import("engine/rhi/types.zig").PrimitiveType;
    pub const SamplerAddressMode = @import("engine/rhi/types.zig").SamplerAddressMode;
    pub const SamplerFilter = @import("engine/rhi/types.zig").SamplerFilter;
    pub const SamplerMipmapMode = @import("engine/rhi/types.zig").SamplerMipmapMode;
    pub const ShaderFormat = @import("engine/rhi/types.zig").ShaderFormat;
    pub const ShaderStage = @import("engine/rhi/types.zig").ShaderStage;
    pub const TextureUsage = @import("engine/rhi/types.zig").TextureUsage;
    pub const BufferDesc = @import("engine/rhi/types.zig").BufferDesc;
    pub const TextureDesc = @import("engine/rhi/types.zig").TextureDesc;
    pub const TransferBufferDesc = @import("engine/rhi/types.zig").TransferBufferDesc;
    pub const VertexElementFormat = @import("engine/rhi/types.zig").VertexElementFormat;
    pub const VertexInputRate = @import("engine/rhi/types.zig").VertexInputRate;
    pub const ClearState = @import("engine/rhi/types.zig").ClearState;
    pub const RuntimeInfo = @import("engine/rhi/types.zig").RuntimeInfo;
    pub const graphicsApiName = @import("engine/rhi/types.zig").graphicsApiName;
};

pub const render = struct {
    pub const GraphicsAPI = @import("engine/render/types.zig").GraphicsAPI;
    pub const BackendSelectionPolicy = @import("engine/render/types.zig").BackendSelectionPolicy;
    pub const RuntimeInfo = @import("engine/render/types.zig").RuntimeInfo;
    pub const Renderer = @import("engine/render/renderer.zig").Renderer;
    pub const RendererConfig = @import("engine/render/renderer.zig").RendererConfig;
    pub const FrameReport = @import("engine/render/renderer.zig").FrameReport;
    pub const graphicsApiName = @import("engine/render/types.zig").graphicsApiName;
};

pub const assets = struct {
    pub const ResourceLibrary = @import("engine/assets/library.zig").ResourceLibrary;
    pub const MeshHandle = @import("engine/assets/handles.zig").MeshHandle;
    pub const MaterialHandle = @import("engine/assets/handles.zig").MaterialHandle;
    pub const TextureHandle = @import("engine/assets/handles.zig").TextureHandle;
    pub const MeshResource = @import("engine/assets/mesh_resource.zig").MeshResource;
    pub const MeshResourceDesc = @import("engine/assets/mesh_resource.zig").MeshResourceDesc;
    pub const MaterialResource = @import("engine/assets/material_resource.zig").MaterialResource;
    pub const MaterialResourceDesc = @import("engine/assets/material_resource.zig").MaterialResourceDesc;
    pub const TextureResource = @import("engine/assets/texture_resource.zig").TextureResource;
    pub const TextureResourceDesc = @import("engine/assets/texture_resource.zig").TextureResourceDesc;
    pub const GltfImportReport = @import("engine/assets/gltf_import.zig").ImportReport;
};

pub const scene = struct {
    pub const Scene = @import("engine/scene/scene.zig").Scene;
    pub const World = @import("engine/scene/scene.zig").World;
    pub const Entity = @import("engine/scene/scene.zig").Entity;
    pub const EntityId = @import("engine/scene/scene.zig").EntityId;
    pub const EntityDesc = @import("engine/scene/scene.zig").EntityDesc;
    pub const Summary = @import("engine/scene/scene.zig").Summary;
    pub const Transform = @import("engine/scene/components.zig").Transform;
    pub const Camera = @import("engine/scene/components.zig").Camera;
    pub const Mesh = @import("engine/scene/components.zig").Mesh;
    pub const Material = @import("engine/scene/components.zig").Material;
    pub const Light = @import("engine/scene/components.zig").Light;
    pub const Primitive = @import("engine/scene/components.zig").Primitive;
    pub const ShadingModel = @import("engine/scene/components.zig").ShadingModel;
    pub const LightKind = @import("engine/scene/components.zig").LightKind;
};

test {
    std.testing.refAllDecls(@This());
}
