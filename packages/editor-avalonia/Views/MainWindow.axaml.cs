using System;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Threading;
using Guava.Editor.Services;
using Guava.Editor.ViewModels;

namespace Guava.Editor.Views;

public partial class MainWindow : Window
{
    private EngineRpcClient? _rpc;

    public MainWindow()
    {
        InitializeComponent();
        Opened += OnOpened;
        Closed += OnClosed;
    }

    private async void OnOpened(object? sender, EventArgs e)
    {
        var vm = DataContext as MainWindowViewModel;
        if (vm == null) return;

        _rpc = new EngineRpcClient();

        // Subscribe to viewport metrics for FPS display
        _rpc.OnNotification += (method, parms) =>
        {
            if (method == "on:viewport.metrics")
            {
                Dispatcher.UIThread.Post(() =>
                {
                    try
                    {
                        var fps = parms.GetProperty("fps").GetInt32();
                        var dc = parms.GetProperty("drawCalls").GetInt32();
                        var tri = parms.GetProperty("triangles").GetInt32();
                        vm.FpsText = $"{fps} FPS | {dc} DC | {tri/1000}K Tri";
                    }
                    catch { }
                });
            }
        };

        var connected = await _rpc.ConnectAsync();
        if (connected)
        {
            vm.ConnectionStatus = "✅ Engine connected";
            vm.StatusText = "Connected to engine — requesting viewport surface...";

            // Set viewport rect
            try
            {
                var bounds = ViewportHost.Bounds;
                var w = (int)(bounds.Width > 0 ? bounds.Width * 2 : 1600); // retina
                var h = (int)(bounds.Height > 0 ? bounds.Height * 2 : 1000);

                await _rpc.InvokeAsync("viewport.setRect", new { x = 0, y = 0, width = w, height = h });

                // Get IOSurface ID
                var result = await _rpc.InvokeAsync("viewport.getSurfaceId");
                if (result.TryGetProperty("surfaceId", out var sid))
                {
                    var surfaceId = sid.GetUInt32();
                    vm.SurfaceId = surfaceId;
                    ViewportHost.SurfaceId = surfaceId;
                    vm.StatusText = $"Viewport active — IOSurface ID: {surfaceId}";
                }
                else
                {
                    vm.StatusText = "Engine connected but no surface ID returned (engine may need a scene open)";
                }
            }
            catch (Exception ex)
            {
                vm.StatusText = $"RPC error: {ex.Message}";
            }
        }
        else
        {
            vm.ConnectionStatus = "⚠ Engine not running";
            vm.StatusText = "Engine not connected — viewport shows placeholder. Floating overlays still work!";
        }
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _rpc?.Dispose();
    }
}