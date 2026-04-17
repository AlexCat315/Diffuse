using CommunityToolkit.Mvvm.ComponentModel;
using Dock.Model.Mvvm.Controls;

namespace Guava.Editor.ViewModels.Panels;

public partial class ViewportPanelViewModel : Document
{
    [ObservableProperty]
    private string _connectionStatus = "Connecting...";

    [ObservableProperty]
    private string _fpsText = "-- FPS";

    [ObservableProperty]
    private uint _surfaceId;

    public ViewportPanelViewModel()
    {
        Id = "Viewport";
        Title = "Viewport";
        CanClose = false;
        CanFloat = false;
    }
}
