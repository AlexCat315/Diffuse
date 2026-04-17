using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Guava.Editor.Services;

/// <summary>
/// JSON-RPC 2.0 client over WebSocket for the Guava engine.
///
/// Features:
///  • Auto-reconnect with back-off
///  • State machine (ConnectionState) with change notification
///  • Subscribe API (method name → many handlers) with IDisposable tokens
///  • Per-call cancellation + configurable timeout
///  • Pending call rejection on disconnect
///
/// Not covered here (delegated to facades in Services/EngineApi/*):
///  • Typed method signatures for specific engine namespaces.
/// </summary>
public sealed class EngineRpcClient : IEngineRpcClient
{
    private static readonly TimeSpan DefaultCallTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan ReconnectDelay = TimeSpan.FromSeconds(1.5);

    // Connection state --------------------------------------------------------
    private readonly object _stateLock = new();
    private ConnectionState _state = ConnectionState.Disconnected;
    public ConnectionState State
    {
        get { lock (_stateLock) return _state; }
    }
    public bool IsConnected => State == ConnectionState.Connected;
    public event Action<ConnectionState>? StateChanged;

    // Notifications -----------------------------------------------------------
    public event Action<string, JsonElement>? Notification;

    private readonly object _subLock = new();
    private readonly Dictionary<string, List<Action<JsonElement>>> _subscriptions = new();

    // Pending calls -----------------------------------------------------------
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> _pending = new();
    private int _nextId;

    // Socket / lifecycle ------------------------------------------------------
    private ClientWebSocket? _ws;
    private CancellationTokenSource? _loopCts;
    private string _url = "ws://127.0.0.1:9100";
    private bool _autoReconnect;
    private bool _disposed;

    // ---------------------------------------------------------------- public

    public async Task<bool> ConnectAsync(string url = "ws://127.0.0.1:9100", CancellationToken ct = default)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(EngineRpcClient));
        _url = url;
        _autoReconnect = true;
        return await TryConnectOnceAsync(ct).ConfigureAwait(false);
    }

    public async Task DisconnectAsync()
    {
        _autoReconnect = false;
        _loopCts?.Cancel();
        FailAllPending(new OperationCanceledException("Client disconnected"));
        if (_ws is { State: WebSocketState.Open })
        {
            try { await _ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None); }
            catch { /* swallow — teardown */ }
        }
        _ws?.Dispose();
        _ws = null;
        SetState(ConnectionState.Disconnected);
    }

    public Task<JsonElement> InvokeAsync(string method, object? parameters = null, CancellationToken ct = default)
        => InvokeCoreAsync(method, parameters, ct);

    public async Task<T?> InvokeAsync<T>(string method, object? parameters = null, CancellationToken ct = default)
    {
        var el = await InvokeCoreAsync(method, parameters, ct).ConfigureAwait(false);
        if (el.ValueKind == JsonValueKind.Undefined || el.ValueKind == JsonValueKind.Null) return default;
        return el.Deserialize<T>();
    }

    public IDisposable Subscribe(string method, Action<JsonElement> handler)
    {
        lock (_subLock)
        {
            if (!_subscriptions.TryGetValue(method, out var list))
                _subscriptions[method] = list = new();
            list.Add(handler);
        }
        return new Unsubscriber(this, method, handler);
    }

    public IDisposable Subscribe<T>(string method, Action<T?> handler)
    {
        return Subscribe(method, el =>
        {
            T? payload = default;
            try { payload = el.Deserialize<T>(); }
            catch { /* keep default on malformed */ }
            handler(payload);
        });
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _ = DisconnectAsync();
    }

    // ---------------------------------------------------------------- private

    private async Task<bool> TryConnectOnceAsync(CancellationToken ct)
    {
        SetState(ConnectionState.Connecting);

        _ws?.Dispose();
        _ws = new ClientWebSocket();
        _loopCts = new CancellationTokenSource();

        try
        {
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(TimeSpan.FromSeconds(5));
            await _ws.ConnectAsync(new Uri(_url), timeoutCts.Token).ConfigureAwait(false);
            SetState(ConnectionState.Connected);
            _ = Task.Run(() => ReceiveLoopAsync(_loopCts.Token));
            return true;
        }
        catch
        {
            SetState(ConnectionState.Failed);
            if (_autoReconnect) ScheduleReconnect();
            return false;
        }
    }

    private void ScheduleReconnect()
    {
        _ = Task.Run(async () =>
        {
            SetState(ConnectionState.Reconnecting);
            await Task.Delay(ReconnectDelay).ConfigureAwait(false);
            if (!_autoReconnect || _disposed) return;
            await TryConnectOnceAsync(CancellationToken.None).ConfigureAwait(false);
        });
    }

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        var sb = new StringBuilder();

        try
        {
            while (!ct.IsCancellationRequested && _ws is { State: WebSocketState.Open })
            {
                WebSocketReceiveResult result;
                try { result = await _ws.ReceiveAsync(buffer, ct).ConfigureAwait(false); }
                catch { break; }

                if (result.MessageType == WebSocketMessageType.Close) break;

                sb.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));
                if (result.EndOfMessage)
                {
                    DispatchMessage(sb.ToString());
                    sb.Clear();
                }
            }
        }
        finally
        {
            FailAllPending(new Exception("Engine disconnected"));
            SetState(ConnectionState.Disconnected);
            if (_autoReconnect && !_disposed) ScheduleReconnect();
        }
    }

    private void DispatchMessage(string json)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(json); }
        catch { return; }

        using (doc)
        {
            var root = doc.RootElement;

            if (root.TryGetProperty("id", out var idProp) && idProp.TryGetInt32(out var id))
            {
                if (_pending.TryRemove(id, out var tcs))
                {
                    if (root.TryGetProperty("error", out var errEl))
                    {
                        var msg = errEl.TryGetProperty("message", out var m) ? m.GetString() : errEl.ToString();
                        tcs.TrySetException(new EngineRpcException(msg ?? "RPC error"));
                    }
                    else if (root.TryGetProperty("result", out var resEl))
                    {
                        tcs.TrySetResult(resEl.Clone());
                    }
                    else
                    {
                        tcs.TrySetResult(default);
                    }
                }
                return;
            }

            if (root.TryGetProperty("method", out var methodProp))
            {
                var method = methodProp.GetString() ?? string.Empty;
                var parms = root.TryGetProperty("params", out var p) ? p.Clone() : default;

                // Global subscriber
                try { Notification?.Invoke(method, parms); }
                catch { /* never let a bad handler break the loop */ }

                // Per-method subscribers
                List<Action<JsonElement>>? copy = null;
                lock (_subLock)
                {
                    if (_subscriptions.TryGetValue(method, out var list))
                        copy = new List<Action<JsonElement>>(list);
                }
                if (copy != null)
                {
                    foreach (var h in copy)
                    {
                        try { h(parms); } catch { /* swallow */ }
                    }
                }
            }
        }
    }

    private async Task<JsonElement> InvokeCoreAsync(string method, object? parameters, CancellationToken ct)
    {
        if (_ws is not { State: WebSocketState.Open })
            throw new InvalidOperationException("Engine not connected");

        var id = Interlocked.Increment(ref _nextId);
        var tcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = tcs;

        var payload = JsonSerializer.Serialize(new
        {
            jsonrpc = "2.0",
            id,
            method,
            @params = parameters ?? new { },
        });
        var bytes = Encoding.UTF8.GetBytes(payload);

        try
        {
            await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _pending.TryRemove(id, out _);
            throw new EngineRpcException($"Send failed: {ex.Message}", ex);
        }

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(DefaultCallTimeout);
        await using var reg = timeoutCts.Token.Register(() =>
        {
            if (_pending.TryRemove(id, out var t))
                t.TrySetException(new TimeoutException($"RPC timeout: {method}"));
        }).ConfigureAwait(false);

        return await tcs.Task.ConfigureAwait(false);
    }

    private void FailAllPending(Exception ex)
    {
        foreach (var kv in _pending)
        {
            if (_pending.TryRemove(kv.Key, out var tcs))
                tcs.TrySetException(ex);
        }
    }

    private void SetState(ConnectionState next)
    {
        bool changed;
        lock (_stateLock)
        {
            changed = _state != next;
            _state = next;
        }
        if (changed)
        {
            try { StateChanged?.Invoke(next); }
            catch { /* never break on handler */ }
        }
    }

    private void RemoveSubscription(string method, Action<JsonElement> handler)
    {
        lock (_subLock)
        {
            if (_subscriptions.TryGetValue(method, out var list))
            {
                list.Remove(handler);
                if (list.Count == 0) _subscriptions.Remove(method);
            }
        }
    }

    private sealed class Unsubscriber : IDisposable
    {
        private readonly EngineRpcClient _owner;
        private readonly string _method;
        private readonly Action<JsonElement> _handler;
        private bool _disposed;

        public Unsubscriber(EngineRpcClient owner, string method, Action<JsonElement> handler)
        {
            _owner = owner; _method = method; _handler = handler;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _owner.RemoveSubscription(_method, _handler);
        }
    }
}

public sealed class EngineRpcException : Exception
{
    public EngineRpcException(string message) : base(message) { }
    public EngineRpcException(string message, Exception inner) : base(message, inner) { }
}
