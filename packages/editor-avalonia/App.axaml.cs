using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Styling;
using Guava.Editor.Services;
using Guava.Editor.ViewModels;
using Guava.Editor.Views;

namespace Guava.Editor;

public partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        // Touch I18n so the default language loads before any view binds to it.
        _ = I18nService.Instance;

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow
            {
                DataContext = new MainWindowViewModel(),
            };
        }

        base.OnFrameworkInitializationCompleted();
    }

    /// <summary>Flip between Dark and Light theme variants.</summary>
    public void ToggleTheme()
    {
        RequestedThemeVariant = RequestedThemeVariant == ThemeVariant.Light
            ? ThemeVariant.Dark
            : ThemeVariant.Light;
    }

    /// <summary>Flip UI language (currently en ↔ zh).</summary>
    public void ToggleLanguage()
    {
        var svc = I18nService.Instance;
        svc.Language = svc.Language == "en" ? "zh" : "en";
    }
}
