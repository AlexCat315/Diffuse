using CommunityToolkit.Mvvm.ComponentModel;

namespace Guava.Editor.ViewModels;

public partial class MainWindowViewModel : ViewModelBase
{
    [ObservableProperty]
    private string _connectionStatus = "Connecting to engine...";

    [ObservableProperty]
    private string _fpsText = "-- FPS | 0 DC | 0 Tri";

    [ObservableProperty]
    private string _statusText = "Avalonia Viewport PoC — validating IOSurface + floating overlay compositing";

    [ObservableProperty]
    private uint _surfaceId;
}
