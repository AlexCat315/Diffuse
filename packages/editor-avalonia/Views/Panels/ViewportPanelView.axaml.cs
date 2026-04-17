using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Threading;
using Guava.Editor.Services;
using Guava.Editor.ViewModels.Panels;

namespace Guava.Editor.Views.Panels;

public partial class ViewportPanelView : UserControl
{
    private EngineRpcClient? _rpc;

    public ViewportPanelView()
    {
        InitializeComponent();
        AttachedToVisualTree += OnAttached;
        DetachedFromVisualTree += OnDetached;
    }

    private async void OnAttached(object? sender, VisualTreeAttachmentEventArgs e)
    {
        if (_rpc != null) return; // already connected
        var vm = DataContext as ViewportPanelViewModel;
        if (vm == null) return;

        _rpc = new EngineRpcClient();

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
                        vm.FpsText = $"{fps} FPS | {dc} DC | {tri / 1000}K Tri";
                    }
                    catch { }
                });
            }
        };

        var connected = await _rpc.ConnectAsync();
        if (connected)
        {
            vm.ConnectionStatus = "✅ Connected";

            try
            {
                var bounds = ViewportHost.Bounds;
                var w = (int)(bounds.Width > 0 ? bounds.Width * 2 : 1600);
                var h = (int)(bounds.Height > 0 ? bounds.Height * 2 : 1000);

                await _rpc.InvokeAsync("viewport.setRect", new { x = 0, y = 0, width = w, height = h });

                var result = await _rpc.InvokeAsync("viewport.getSurfaceId");
                if (result.TryGetProperty("surfaceId", out var sid))
                {
                    var surfaceId = sid.GetUInt32();
                    vm.SurfaceId = surfaceId;
                    ViewportHost.SurfaceId = surfaceId;
                }
            }
            catch (Exception ex)
            {
                vm.ConnectionStatus = $"⚠ RPC error: {ex.Message}";
            }
        }
        else
        {
            vm.ConnectionStatus = "⚠ Engine offline";
        }
    }

    private void OnDetached(object? sender, VisualTreeAttachmentEventArgs e)
    {
        _rpc?.Dispose();
        _rpc = null;
    }
}
