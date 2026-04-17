using System;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using Dock.Model.Mvvm.Controls;
using Guava.Editor.Services;

namespace Guava.Editor.ViewModels.Panels;

/// <summary>
/// Viewport document VM.
///
/// Responsibilities:
///  • On RPC connection, push initial rect, poll viewport.getSurfaceId until a
///    non-zero surfaceId is returned, then expose it to the view via
///    <see cref="SurfaceId"/> so <c>IOSurfaceHost</c> starts rendering.
///  • On size change (view raises <see cref="NotifyResize"/>), issue
///    viewport.setRect and re-poll for a (possibly new) surfaceId.
///  • Display FPS / DrawCalls via on:viewport.metrics subscription.
/// </summary>
public partial class ViewportPanelViewModel : Document
{
    private const int PollAttempts = 20;
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(250);

    private readonly IEngineRpcClient _rpc;
    private readonly ViewportApi _viewport;
    private IDisposable? _metricsSub;
    private int _lastWidth;
    private int _lastHeight;
    private CancellationTokenSource? _pollCts;

    [ObservableProperty] private uint _surfaceId;
    [ObservableProperty] private string _fpsText = "-- FPS";
    [ObservableProperty] private string _drawCallsText = "";
    [ObservableProperty] private string _statusText = "Waiting for engine…";

    public ViewportPanelViewModel() : this(
        ServiceLocator.TryGet<IEngineRpcClient>() ?? new NullRpcClient())
    { }

    public ViewportPanelViewModel(IEngineRpcClient rpc)
    {
        Id = "Viewport";
        Title = "Viewport";
        CanClose = false;
        CanFloat = false;

        _rpc = rpc;
        _viewport = new ViewportApi(rpc);

        _rpc.StateChanged += OnRpcStateChanged;
        _metricsSub = _rpc.Subscribe<ViewportMetrics>("on:viewport.metrics", OnMetrics);

        // If already connected when panel is constructed, kick off immediately.
        if (_rpc.IsConnected) QueueSurfaceSync(_lastWidth, _lastHeight);
    }

    /// <summary>Called by the View whenever its render bounds change.</summary>
    public void NotifyResize(int width, int height)
    {
        if (width <= 0 || height <= 0) return;
        if (width == _lastWidth && height == _lastHeight) return;
        _lastWidth = width;
        _lastHeight = height;
        QueueSurfaceSync(width, height);
    }

    private void OnRpcStateChanged(ConnectionState state)
    {
        Dispatcher.UIThread.Post(() =>
        {
            switch (state)
            {
                case ConnectionState.Connected:
                    StatusText = "Connected";
                    QueueSurfaceSync(_lastWidth, _lastHeight);
                    break;
                case ConnectionState.Connecting:
                    StatusText = "Connecting…";
                    break;
                case ConnectionState.Reconnecting:
                    StatusText = "Reconnecting…";
                    SurfaceId = 0;
                    break;
                case ConnectionState.Disconnected:
                case ConnectionState.Failed:
                    StatusText = "Engine offline";
                    SurfaceId = 0;
                    break;
            }
        });
    }

    private void QueueSurfaceSync(int width, int height)
    {
        _pollCts?.Cancel();
        _pollCts = new CancellationTokenSource();
        var ct = _pollCts.Token;
        _ = Task.Run(async () =>
        {
            if (!_rpc.IsConnected) return;

            // Announce the desired viewport rect (engine may recreate surface).
            if (width > 0 && height > 0)
            {
                try { await _viewport.SetRectAsync(0, 0, width, height, ct).ConfigureAwait(false); }
                catch { /* engine may still be spinning up */ }
            }

            // Poll for a valid surface id.
            for (int attempt = 0; attempt < PollAttempts && !ct.IsCancellationRequested; attempt++)
            {
                try
                {
                    var info = await _viewport.GetSurfaceIdAsync(ct).ConfigureAwait(false);
                    if (info is { SurfaceId: > 0 } && info.SurfaceId != SurfaceId)
                    {
                        var id = info.SurfaceId;
                        Dispatcher.UIThread.Post(() => SurfaceId = id);
                        return;
                    }
                }
                catch { /* keep trying */ }

                try { await Task.Delay(PollInterval, ct).ConfigureAwait(false); }
                catch { return; }
            }
        }, ct);
    }

    private void OnMetrics(ViewportMetrics? m)
    {
        if (m == null) return;
        Dispatcher.UIThread.Post(() =>
        {
            FpsText = $"{m.Fps:0} FPS";
            DrawCallsText = m.DrawCalls is { } dc ? $"{dc} draws" : "";
        });
    }

    public sealed class ViewportMetrics
    {
        [System.Text.Json.Serialization.JsonPropertyName("fps")] public double Fps { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("drawCalls")] public int? DrawCalls { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("triangles")] public long? Triangles { get; set; }
    }

    // ------------------------------------------------------------ fallback

    /// <summary>No-op RPC client used by design-time constructors.</summary>
    private sealed class NullRpcClient : IEngineRpcClient
    {
        public ConnectionState State => ConnectionState.Disconnected;
        public bool IsConnected => false;
        public event Action<ConnectionState>? StateChanged { add { } remove { } }
        public event Action<string, System.Text.Json.JsonElement>? Notification { add { } remove { } }
        public Task<bool> ConnectAsync(string url = "ws://127.0.0.1:9100", CancellationToken ct = default) => Task.FromResult(false);
        public Task DisconnectAsync() => Task.CompletedTask;
        public Task<System.Text.Json.JsonElement> InvokeAsync(string method, object? parameters = null, CancellationToken ct = default) =>
            Task.FromException<System.Text.Json.JsonElement>(new InvalidOperationException("Not connected"));
        public Task<T?> InvokeAsync<T>(string method, object? parameters = null, CancellationToken ct = default) =>
            Task.FromResult<T?>(default);
        public IDisposable Subscribe(string method, Action<System.Text.Json.JsonElement> handler) => new Nop();
        public IDisposable Subscribe<T>(string method, Action<T?> handler) => new Nop();
        public void Dispose() { }
        private sealed class Nop : IDisposable { public void Dispose() { } }
    }
}
