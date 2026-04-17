using Avalonia.Controls;
using Avalonia.Markup.Xaml;
using Guava.Editor.ViewModels.Panels;

namespace Guava.Editor.Views.Panels;

public partial class ViewportPanelView : UserControl
{
    public ViewportPanelView()
    {
        InitializeComponent();
    }

    private void InitializeComponent()
    {
        AvaloniaXamlLoader.Load(this);
    }

    private void OnRootSizeChanged(object? sender, SizeChangedEventArgs e)
    {
        if (DataContext is ViewportPanelViewModel vm)
        {
            vm.NotifyResize((int)e.NewSize.Width, (int)e.NewSize.Height);
        }
    }
}
