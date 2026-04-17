using Dock.Model.Mvvm.Controls;

namespace Guava.Editor.ViewModels.Panels;

public class InspectorPanelViewModel : Tool
{
    public InspectorPanelViewModel()
    {
        Id = "Inspector";
        Title = "Inspector";
        CanClose = true;
        CanPin = true;
    }
}
