using System;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Styling;
using Avalonia.Threading;
using Guava.Editor.Services;
using Guava.Editor.State;
using Guava.Editor.ViewModels;
using Guava.Editor.Views;

namespace Guava.Editor;

public partial class App : Application
{
    private EngineProcessService? _engineProcess;
    private EngineRpcClient? _rpcClient;

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        Log.Info($"Editor startup · BaseDir={AppContext.BaseDirectory}");
        // Load persisted preferences BEFORE I18n/theme consumers bind.
        var prefs = AppPreferencesStore.Load();
        Log.Info($"Prefs loaded · lang={prefs.Language} theme={prefs.ThemeVariant}");
        ServiceLocator.Register(prefs);

        I18nService.Instance.Language = prefs.Language;
        RequestedThemeVariant = prefs.ThemeVariant == "Light" ? ThemeVariant.Light : ThemeVariant.Dark;

        BootstrapServices();

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow
            {
                DataContext = new MainWindowViewModel(),
            };
            desktop.ShutdownRequested += OnShutdownRequested;
        }

        base.OnFrameworkInitializationCompleted();

        // Launch engine + establish RPC after window is up so users see "Connecting…"
        Dispatcher.UIThread.Post(StartEngineAsync, DispatcherPriority.Background);
    }

    private void BootstrapServices()
    {
        _rpcClient = new EngineRpcClient();
        var connectionStore = new ConnectionStore();
        connectionStore.Attach(_rpcClient);

        _engineProcess = new EngineProcessService();

        ServiceLocator.Register<IEngineRpcClient>(_rpcClient);
        ServiceLocator.Register(connectionStore);
        ServiceLocator.Register(_engineProcess);
        ServiceLocator.Register(new EditorApi(_rpcClient));
        ServiceLocator.Register(new ViewportApi(_rpcClient));
        ServiceLocator.Register(new SceneApi(_rpcClient));
    }

    private async void StartEngineAsync()
    {
        if (_engineProcess == null || _rpcClient == null) return;

        // 1) Spawn the engine subprocess (best-effort — user may already have
        //    one running externally; ConnectAsync will find it either way).
        _engineProcess.Start(projectPath: null, port: 9100);

        // 2) Give the WebSocket server a moment to come up before first connect.
        await System.Threading.Tasks.Task.Delay(400);

        // 3) Connect with auto-reconnect enabled.
        try
        {
            await _rpcClient.ConnectAsync($"ws://127.0.0.1:{_engineProcess.Port}");
        }
        catch { /* state machine will expose the failure via ConnectionStore */ }
    }

    private void OnShutdownRequested(object? sender, ShutdownRequestedEventArgs e)
    {
        try { _rpcClient?.Dispose(); } catch { }
        try { _engineProcess?.Dispose(); } catch { }
    }

    /// <summary>Flip between Dark and Light theme variants.</summary>
    public void ToggleTheme()
    {
        var next = RequestedThemeVariant == ThemeVariant.Light ? ThemeVariant.Dark : ThemeVariant.Light;
        RequestedThemeVariant = next;
        if (ServiceLocator.TryGet<AppPreferencesStore>() is { } prefs)
            prefs.ThemeVariant = next == ThemeVariant.Light ? "Light" : "Dark";
    }

    /// <summary>Flip UI language (currently en ↔ zh).</summary>
    public void ToggleLanguage()
    {
        var svc = I18nService.Instance;
        var next = svc.Language == "en" ? "zh" : "en";
        Log.Info($"ToggleLanguage · {svc.Language} → {next}");
        svc.Language = next;
        if (ServiceLocator.TryGet<AppPreferencesStore>() is { } prefs)
            prefs.Language = svc.Language;
    }
}
