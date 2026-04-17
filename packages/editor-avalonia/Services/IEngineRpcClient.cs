using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Guava.Editor.Services;

public interface IEngineRpcClient : IDisposable
{
    ConnectionState State { get; }
    bool IsConnected { get; }

    event Action<ConnectionState>? StateChanged;

    /// <summary>Fired for every incoming JSON-RPC notification. method name + raw params.</summary>
    event Action<string, JsonElement>? Notification;

    /// <summary>Start connecting. Returns true when handshake (editor.ping) succeeds.</summary>
    Task<bool> ConnectAsync(string url = "ws://127.0.0.1:9100", CancellationToken ct = default);

    /// <summary>Stop and cancel auto-reconnect.</summary>
    Task DisconnectAsync();

    /// <summary>Raw RPC call. Prefer typed API facades in Services/EngineApi.</summary>
    Task<JsonElement> InvokeAsync(string method, object? parameters = null, CancellationToken ct = default);

    /// <summary>Raw RPC call with typed result.</summary>
    Task<T?> InvokeAsync<T>(string method, object? parameters = null, CancellationToken ct = default);

    /// <summary>Subscribe to a specific notification. Returns IDisposable to unsubscribe.</summary>
    IDisposable Subscribe(string method, Action<JsonElement> handler);

    /// <summary>Subscribe and deserialize into a typed payload.</summary>
    IDisposable Subscribe<T>(string method, Action<T?> handler);
}
