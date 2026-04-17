using System;
using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Guava.Editor.Services;

/// <summary>
/// Minimal JSON-RPC 2.0 client over WebSocket for communicating with the Guava engine.
/// </summary>
public class EngineRpcClient : IDisposable
{
    private readonly ClientWebSocket _ws = new();
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> _pending = new();
    private int _nextId;
    private CancellationTokenSource? _cts;

    public event Action<string, JsonElement>? OnNotification;
    public bool IsConnected => _ws.State == WebSocketState.Open;

    public async Task<bool> ConnectAsync(string url = "ws://127.0.0.1:9100", int timeoutMs = 5000)
    {
        try
        {
            _cts = new CancellationTokenSource();
            using var connectCts = new CancellationTokenSource(timeoutMs);
            await _ws.ConnectAsync(new Uri(url), connectCts.Token);
            _ = Task.Run(ReceiveLoopAsync);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public async Task<JsonElement> InvokeAsync(string method, object? parameters = null)
    {
        var id = Interlocked.Increment(ref _nextId);
        var tcs = new TaskCompletionSource<JsonElement>();
        _pending[id] = tcs;

        var msg = JsonSerializer.Serialize(new
        {
            jsonrpc = "2.0",
            id,
            method,
            @params = parameters
        });

        var bytes = Encoding.UTF8.GetBytes(msg);
        await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, _cts?.Token ?? CancellationToken.None);

        using var timeout = new CancellationTokenSource(10000);
        timeout.Token.Register(() => tcs.TrySetCanceled());

        return await tcs.Task;
    }

    public async Task<T?> InvokeAsync<T>(string method, object? parameters = null)
    {
        var result = await InvokeAsync(method, parameters);
        return result.Deserialize<T>();
    }

    private async Task ReceiveLoopAsync()
    {
        var buffer = new byte[65536];
        var sb = new StringBuilder();

        while (_ws.State == WebSocketState.Open && !(_cts?.IsCancellationRequested ?? true))
        {
            try
            {
                var result = await _ws.ReceiveAsync(buffer, _cts!.Token);
                if (result.MessageType == WebSocketMessageType.Close) break;

                sb.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));

                if (result.EndOfMessage)
                {
                    ProcessMessage(sb.ToString());
                    sb.Clear();
                }
            }
            catch
            {
                break;
            }
        }
    }

    private void ProcessMessage(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            if (root.TryGetProperty("id", out var idProp) && idProp.TryGetInt32(out var id))
            {
                if (_pending.TryRemove(id, out var tcs))
                {
                    if (root.TryGetProperty("result", out var result))
                        tcs.TrySetResult(result.Clone());
                    else if (root.TryGetProperty("error", out var error))
                        tcs.TrySetException(new Exception(error.ToString()));
                    else
                        tcs.TrySetResult(default);
                }
            }
            else if (root.TryGetProperty("method", out var methodProp))
            {
                var method = methodProp.GetString() ?? "";
                root.TryGetProperty("params", out var parms);
                OnNotification?.Invoke(method, parms.Clone());
            }
        }
        catch { /* ignore malformed messages */ }
    }

    public void Dispose()
    {
        _cts?.Cancel();
        _ws.Dispose();
        _cts?.Dispose();
    }
}
