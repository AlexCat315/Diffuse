using CommunityToolkit.Mvvm.ComponentModel;
using Dock.Model.Controls;

namespace Guava.Editor.ViewModels;

public partial class MainWindowViewModel : ViewModelBase
{
    [ObservableProperty]
    private string _connectionStatus = "";

    [ObservableProperty]
    private string _statusText = "Guava Editor";

    private IRootDock? _layout;
    public IRootDock? Layout
    {
        get => _layout;
        set => SetProperty(ref _layout, value);
    }

    private readonly DockFactory _factory;

    public MainWindowViewModel()
    {
        _factory = new DockFactory();
        var layout = _factory.CreateLayout();
        _factory.InitLayout(layout);
        Layout = layout;
    }
}
