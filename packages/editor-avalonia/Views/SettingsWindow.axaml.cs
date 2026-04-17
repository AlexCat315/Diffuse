using Avalonia.Controls;
using Avalonia.Markup.Xaml;

namespace Guava.Editor.Views;

public partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
    }

    private void InitializeComponent()
    {
        AvaloniaXamlLoader.Load(this);
    }
}
