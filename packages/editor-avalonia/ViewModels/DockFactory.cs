using System;
using System.Collections.Generic;
using Dock.Avalonia.Controls;
using Dock.Model.Controls;
using Dock.Model.Core;
using Dock.Model.Mvvm;
using Dock.Model.Mvvm.Controls;
using Guava.Editor.ViewModels.Panels;
using Guava.Editor.Views.Panels;

namespace Guava.Editor.ViewModels;

public class DockFactory : Factory
{
    private IRootDock? _rootDock;
    private IDocumentDock? _documentDock;

    public override IRootDock CreateLayout()
    {
        // --- Documents (center) ---
        var viewport = new ViewportPanelViewModel();

        var documentDock = new DocumentDock
        {
            IsCollapsable = false,
            ActiveDockable = viewport,
            VisibleDockables = CreateList<IDockable>(viewport),
            CanCreateDocument = false,
        };

        // --- Left tools ---
        var sceneHierarchy = new SceneHierarchyPanelViewModel();
        var contentBrowser = new ContentBrowserPanelViewModel();

        var leftDock = new ProportionalDock
        {
            Proportion = 0.18,
            Orientation = Orientation.Vertical,
            VisibleDockables = CreateList<IDockable>(
                new ToolDock
                {
                    ActiveDockable = sceneHierarchy,
                    VisibleDockables = CreateList<IDockable>(sceneHierarchy),
                    Alignment = Alignment.Left,
                    Proportion = 0.6,
                },
                new ProportionalDockSplitter(),
                new ToolDock
                {
                    ActiveDockable = contentBrowser,
                    VisibleDockables = CreateList<IDockable>(contentBrowser),
                    Alignment = Alignment.Left,
                    Proportion = 0.4,
                }
            )
        };

        // --- Right tools ---
        var inspector = new InspectorPanelViewModel();

        var rightDock = new ProportionalDock
        {
            Proportion = 0.20,
            Orientation = Orientation.Vertical,
            VisibleDockables = CreateList<IDockable>(
                new ToolDock
                {
                    ActiveDockable = inspector,
                    VisibleDockables = CreateList<IDockable>(inspector),
                    Alignment = Alignment.Right,
                }
            )
        };

        // --- Bottom tools ---
        var console = new ConsolePanelViewModel();

        var bottomDock = new ProportionalDock
        {
            Proportion = 0.22,
            Orientation = Orientation.Horizontal,
            VisibleDockables = CreateList<IDockable>(
                new ToolDock
                {
                    ActiveDockable = console,
                    VisibleDockables = CreateList<IDockable>(console),
                    Alignment = Alignment.Bottom,
                }
            )
        };

        // --- Main layout: left | center/bottom | right ---
        var centerAndBottom = new ProportionalDock
        {
            Orientation = Orientation.Vertical,
            VisibleDockables = CreateList<IDockable>(
                documentDock,
                new ProportionalDockSplitter(),
                bottomDock
            )
        };

        var mainLayout = new ProportionalDock
        {
            Orientation = Orientation.Horizontal,
            VisibleDockables = CreateList<IDockable>(
                leftDock,
                new ProportionalDockSplitter(),
                centerAndBottom,
                new ProportionalDockSplitter(),
                rightDock
            )
        };

        var rootDock = CreateRootDock();
        rootDock.IsCollapsable = false;
        rootDock.ActiveDockable = mainLayout;
        rootDock.DefaultDockable = mainLayout;
        rootDock.VisibleDockables = CreateList<IDockable>(mainLayout);

        _documentDock = documentDock;
        _rootDock = rootDock;

        return rootDock;
    }

    public override void InitLayout(IDockable layout)
    {
        ContextLocator = new Dictionary<string, Func<object?>>
        {
            ["Viewport"] = () => new ViewportPanelView(),
            ["SceneHierarchy"] = () => new SceneHierarchyPanelView(),
            ["Inspector"] = () => new InspectorPanelView(),
            ["Console"] = () => new ConsolePanelView(),
            ["ContentBrowser"] = () => new ContentBrowserPanelView(),
        };

        DockableLocator = new Dictionary<string, Func<IDockable?>>
        {
            ["Root"] = () => _rootDock,
            ["Documents"] = () => _documentDock,
        };

        HostWindowLocator = new Dictionary<string, Func<IHostWindow?>>
        {
            [nameof(IDockWindow)] = () => new HostWindow()
        };

        base.InitLayout(layout);
    }
}
