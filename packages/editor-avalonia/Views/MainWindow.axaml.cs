using System;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Guava.Editor.Services;
using Guava.Editor.ViewModels;

namespace Guava.Editor.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }

    /// <summary>
    /// Backup Click handler for the Settings cog — bypasses any Command binding
    /// resolution issue so a click is always registered (and logged).
    /// </summary>
    public void OnSettingsClick(object? sender, RoutedEventArgs e)
    {
        Log.Info("[MainWindow] cog button Click fired (code-behind)");
        if (DataContext is MainWindowViewModel vm)
        {
            vm.OpenSettingsCommand.Execute(null);
        }
        else
        {
            Log.Warn($"[MainWindow] DataContext is {DataContext?.GetType().Name ?? "null"} — cannot open Settings");
        }
    }
}
