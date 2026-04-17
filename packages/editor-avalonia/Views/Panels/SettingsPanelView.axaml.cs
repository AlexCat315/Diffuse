using Avalonia.Controls;
using Avalonia.Markup.Xaml;

namespace Guava.Editor.Views.Panels;

public partial class SettingsPanelView : UserControl
{
    public SettingsPanelView()
    {
        InitializeComponent();
    }

    private void InitializeComponent()
    {
        AvaloniaXamlLoader.Load(this);
    }
}
