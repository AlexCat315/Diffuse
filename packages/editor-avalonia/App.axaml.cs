using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Styling;
using Avalonia.Markup.Xaml.Styling;
using System;
using Guava.Editor.ViewModels;
using Guava.Editor.Views;

namespace Guava.Editor;

public partial class App : Application
{
    private static readonly Uri LatteUri = new("avares://Guava.Editor/Themes/CatppuccinLatte.axaml");
    private static readonly Uri NightUri = new("avares://Guava.Editor/Themes/GuavaNight.axaml");

    private bool _isDark;

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow
            {
                DataContext = new MainWindowViewModel(),
            };
        }

        base.OnFrameworkInitializationCompleted();
    }

    public void ToggleTheme()
    {
        _isDark = !_isDark;

        var oldUri = _isDark ? LatteUri : NightUri;
        var newUri = _isDark ? NightUri : LatteUri;

        var merged = Resources.MergedDictionaries;
        for (int i = 0; i < merged.Count; i++)
        {
            if (merged[i] is ResourceInclude ri && ri.Source == oldUri)
            {
                merged[i] = new ResourceInclude(new Uri("avares://Guava.Editor"))
                {
                    Source = newUri
                };
                break;
            }
        }

        RequestedThemeVariant = _isDark ? ThemeVariant.Dark : ThemeVariant.Light;
    }
}