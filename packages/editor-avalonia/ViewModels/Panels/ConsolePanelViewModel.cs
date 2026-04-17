using Dock.Model.Mvvm.Controls;

namespace Guava.Editor.ViewModels.Panels;

public class ConsolePanelViewModel : Tool
{
    public ConsolePanelViewModel()
    {
        Id = "Console";
        Title = "Console";
        CanClose = true;
        CanPin = true;
    }
}
