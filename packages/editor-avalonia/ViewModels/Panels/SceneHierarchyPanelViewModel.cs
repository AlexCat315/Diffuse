using Dock.Model.Mvvm.Controls;

namespace Guava.Editor.ViewModels.Panels;

public class SceneHierarchyPanelViewModel : Tool
{
    public SceneHierarchyPanelViewModel()
    {
        Id = "SceneHierarchy";
        Title = "Scene Hierarchy";
        CanClose = true;
        CanPin = true;
    }
}
