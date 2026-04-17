using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.VisualTree;
using Dock.Model.Core;
using Guava.Editor.Services;
using Guava.Editor.ViewModels;

namespace Guava.Editor.Views;

public partial class MainWindow : Window
{
    // Drag state for the Settings modal card (mirrors React old editor's
    // DraggableSettingsModal: header press → move → release).
    private bool _draggingSettings;
    private Point _dragStart;      // pointer position at press, in window coords
    private double _dragOriginX;   // card's X translation at press
    private double _dragOriginY;   // card's Y translation at press

    /// <summary>
    /// Lazily resolves the <see cref="TranslateTransform"/> attached to the
    /// Settings card so drag updates can mutate it directly.
    /// </summary>
    private TranslateTransform? CardTransform => SettingsCard?.RenderTransform as TranslateTransform;

    public MainWindow()
    {
        InitializeComponent();
        AddHandler(KeyDownEvent, OnWindowKeyDown, handledEventsToo: true);
        // Intercept PointerReleased on the Tunnel phase so we run BEFORE the Button
        // raises its Click event. Setting e.Handled stops the Button from firing
        // OnClick at all, which is required because Dock wires the Pin action
        // directly on the button (Command or Click +=) and we need to suppress it
        // to repurpose the slot as "popout to new window".
        AddHandler(
            InputElement.PointerReleasedEvent,
            OnChromePointerReleased,
            RoutingStrategies.Tunnel);
    }

    /// <summary>
    /// Tunnel-phase interceptor that repurposes the Dock <c>PART_PinButton</c>
    /// chrome slot as a popout-to-new-window trigger. Opens the panel in a
    /// brand-new top-level <see cref="Window"/> (independent OS window with its
    /// own titlebar), detached from the Dock system — mirroring the popout
    /// behaviour of the prior React/Electron editor.
    /// </summary>
    private void OnChromePointerReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (e.InitialPressMouseButton != MouseButton.Left) return;
        if (e.Source is not Visual v) return;
        var btn = (v as Button) ?? v.FindAncestorOfType<Button>();
        if (btn is null || btn.Name != "PART_PinButton") return;
        if (btn.DataContext is not IDock dock) return;
        var dockable = dock.ActiveDockable;
        if (dockable is null) return;

        Log.Info($"[MainWindow] Popout → new Window for '{dockable.Title}'");
        var popout = new Window
        {
            Title = dockable.Title ?? "Panel",
            Width = 640,
            Height = 480,
            DataContext = dockable,
            Content = dockable, // ViewLocator resolves VM → View
        };
        popout.Show();
        e.Handled = true;
    }

    /// <summary>
    /// Toolbar cog button → open Settings. Code-behind click is used in addition
    /// to a Command binding to guarantee the event fires even if the DataContext
    /// resolves late (see prior investigation notes).
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

    // Clicking the dimmed backdrop (but NOT the card) closes Settings.
    public void OnSettingsBackdropPressed(object? sender, PointerPressedEventArgs e)
    {
        if (e.Source is Visual v && SettingsCard.IsVisualAncestorOf(v)) return;
        if (DataContext is MainWindowViewModel vm) vm.CloseSettingsCommand.Execute(null);
    }

    // Swallow presses on the card so they don't bubble up to the backdrop handler.
    public void OnSettingsCardPressed(object? sender, PointerPressedEventArgs e) => e.Handled = true;

    public void OnSettingsHeaderPressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        if (CardTransform is not { } t) return;
        _draggingSettings = true;
        _dragStart = e.GetPosition(this);
        _dragOriginX = t.X;
        _dragOriginY = t.Y;
        e.Pointer.Capture(SettingsHeader);
        e.Handled = true;
    }

    public void OnSettingsHeaderMoved(object? sender, PointerEventArgs e)
    {
        if (!_draggingSettings) return;
        if (CardTransform is not { } t) return;
        var cur = e.GetPosition(this);
        t.X = _dragOriginX + (cur.X - _dragStart.X);
        t.Y = _dragOriginY + (cur.Y - _dragStart.Y);
    }

    public void OnSettingsHeaderReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (!_draggingSettings) return;
        _draggingSettings = false;
        e.Pointer.Capture(null);
    }

    // Escape closes the Settings overlay when it's open.
    private void OnWindowKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape
            && DataContext is MainWindowViewModel vm
            && vm.IsSettingsOpen)
        {
            vm.CloseSettingsCommand.Execute(null);
            e.Handled = true;
        }
    }
}
