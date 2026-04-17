using System;
using CommunityToolkit.Mvvm.ComponentModel;
using Guava.Editor.Services;

namespace Guava.Editor.State;

/// <summary>
/// UI-facing observable wrapper around <see cref="IEngineRpcClient.State"/>.
/// Panels and the main window bind to this store instead of reaching into the
/// RPC client directly.
/// </summary>
public sealed partial class ConnectionStore : ObservableObject
{
    [ObservableProperty]
    private ConnectionState _state = ConnectionState.Disconnected;

    [ObservableProperty]
    private string _statusText = "Disconnected";

    public bool IsConnected => State == ConnectionState.Connected;

    partial void OnStateChanged(ConnectionState value)
    {
        StatusText = value switch
        {
            ConnectionState.Disconnected => "Disconnected",
            ConnectionState.Connecting   => "Connecting…",
            ConnectionState.Connected    => "Connected",
            ConnectionState.Reconnecting => "Reconnecting…",
            ConnectionState.Failed       => "Connection failed",
            _ => "Unknown",
        };
        OnPropertyChanged(nameof(IsConnected));
    }

    public void Attach(IEngineRpcClient rpc)
    {
        State = rpc.State;
        rpc.StateChanged += next =>
        {
            // Marshal to UI thread
            Avalonia.Threading.Dispatcher.UIThread.Post(() => State = next);
        };
    }
}
