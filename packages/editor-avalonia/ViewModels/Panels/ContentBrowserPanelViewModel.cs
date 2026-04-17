using Dock.Model.Mvvm.Controls;

namespace Guava.Editor.ViewModels.Panels;

public class ContentBrowserPanelViewModel : Tool
{
    public ContentBrowserPanelViewModel()
    {
        Id = "ContentBrowser";
        Title = "Content Browser";
        CanClose = true;
        CanPin = true;
    }
}
