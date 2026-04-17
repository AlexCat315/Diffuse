using System.ComponentModel;
using Avalonia;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Dock.Model.Controls;
using Guava.Editor.Services;

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

    public string CurrentLanguageLabel => I18nService.Instance.Language.ToUpperInvariant();

    private readonly DockFactory _factory;

    public MainWindowViewModel()
    {
        _factory = new DockFactory();
        var layout = _factory.CreateLayout();
        _factory.InitLayout(layout);
        Layout = layout;

        I18nService.Instance.PropertyChanged += OnI18nChanged;
    }

    private void OnI18nChanged(object? sender, PropertyChangedEventArgs e)
    {
        OnPropertyChanged(nameof(CurrentLanguageLabel));
    }

    [RelayCommand]
    private void ToggleTheme()
    {
        if (Application.Current is App app) app.ToggleTheme();
    }

    [RelayCommand]
    private void ToggleLanguage()
    {
        if (Application.Current is App app) app.ToggleLanguage();
    }
}
