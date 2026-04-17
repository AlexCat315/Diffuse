using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Guava.Editor.Services;

/// <summary>
/// Typed facade for the "editor.*" namespace.
/// Only the methods currently required by the editor shell are wrapped; the rest
/// are reachable via <see cref="IEngineRpcClient.InvokeAsync"/>.
/// </summary>
public sealed class EditorApi
{
    private readonly IEngineRpcClient _rpc;
    public EditorApi(IEngineRpcClient rpc) => _rpc = rpc;

    public Task PingAsync(CancellationToken ct = default) =>
        _rpc.InvokeAsync("editor.ping", null, ct);

    public Task<Capabilities?> GetCapabilitiesAsync(CancellationToken ct = default) =>
        _rpc.InvokeAsync<Capabilities>("editor.getCapabilities", null, ct);

    public sealed class Capabilities
    {
        [JsonPropertyName("version")] public string? Version { get; set; }
        [JsonPropertyName("platform")] public string? Platform { get; set; }
    }
}

/// <summary>Typed facade for the "viewport.*" namespace.</summary>
public sealed class ViewportApi
{
    private readonly IEngineRpcClient _rpc;
    public ViewportApi(IEngineRpcClient rpc) => _rpc = rpc;

    public Task SetRectAsync(int x, int y, int width, int height, CancellationToken ct = default) =>
        _rpc.InvokeAsync("viewport.setRect", new { x, y, width, height }, ct);

    public Task<SurfaceInfo?> GetSurfaceIdAsync(CancellationToken ct = default) =>
        _rpc.InvokeAsync<SurfaceInfo>("viewport.getSurfaceId", null, ct);

    public sealed class SurfaceInfo
    {
        [JsonPropertyName("surfaceId")] public uint SurfaceId { get; set; }
        [JsonPropertyName("shmName")] public string? ShmName { get; set; }
        [JsonPropertyName("width")] public int? Width { get; set; }
        [JsonPropertyName("height")] public int? Height { get; set; }
    }
}

/// <summary>Typed facade for the "scene.*" namespace (minimal — expanded as panels land).</summary>
public sealed class SceneApi
{
    private readonly IEngineRpcClient _rpc;
    public SceneApi(IEngineRpcClient rpc) => _rpc = rpc;

    public Task<SceneHierarchy?> GetHierarchyAsync(CancellationToken ct = default) =>
        _rpc.InvokeAsync<SceneHierarchy>("scene.getHierarchy", null, ct);

    public sealed class SceneHierarchy
    {
        [JsonPropertyName("entities")] public SceneEntity[]? Entities { get; set; }
    }

    public sealed class SceneEntity
    {
        [JsonPropertyName("id")] public long Id { get; set; }
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("parent")] public long? Parent { get; set; }
        [JsonPropertyName("children")] public long[]? Children { get; set; }
    }
}
