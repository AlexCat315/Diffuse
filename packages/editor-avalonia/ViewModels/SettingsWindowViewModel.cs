using System;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Styling;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Guava.Editor.Services;
using Guava.Editor.State;

namespace Guava.Editor.ViewModels;

/// <summary>
/// VM for the Settings window. Provides a small section list and reflects the
/// shared <see cref="AppPreferencesStore"/>. Changes are persisted on assignment
/// via the store's PropertyChanged hook.
/// </summary>
public sealed partial class SettingsWindowViewModel : ObservableObject
{
    public AppPreferencesStore Prefs { get; }
    public ConnectionStore Connection { get; }

    public string[] Sections { get; } =
    {
        "Language",
        "Appearance",
        "Engine",
        "About",
    };

    [ObservableProperty] private string _selectedSection = "Language";
    [ObservableProperty] private string _engineVersion = "-";
    [ObservableProperty] private string _testStatus = "";
    [ObservableProperty] private bool _isTesting;

    public bool IsDarkTheme
    {
        get => Prefs.ThemeVariant == "Dark";
        set
        {
            Prefs.ThemeVariant = value ? "Dark" : "Light";
            ApplyTheme(Prefs.ThemeVariant);
            OnPropertyChanged();
        }
    }

    public bool IsChinese
    {
        get => Prefs.Language == "zh";
        set
        {
            Prefs.Language = value ? "zh" : "en";
            I18nService.Instance.Language = Prefs.Language;
            OnPropertyChanged();
        }
    }

    public SettingsWindowViewModel()
        : this(ServiceLocator.TryGet<AppPreferencesStore>() ?? AppPreferencesStore.Load(),
               ServiceLocator.TryGet<ConnectionStore>() ?? new ConnectionStore())
    { }

    public SettingsWindowViewModel(AppPreferencesStore prefs, ConnectionStore connection)
    {
        Prefs = prefs;
        Connection = connection;
        Prefs.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppPreferencesStore.ThemeVariant)) OnPropertyChanged(nameof(IsDarkTheme));
            if (e.PropertyName == nameof(AppPreferencesStore.Language))     OnPropertyChanged(nameof(IsChinese));
        };
    }

    [RelayCommand]
    private async Task TestConnection()
    {
        IsTesting = true;
        TestStatus = "Testing…";
        try
        {
            var rpc = ServiceLocator.TryGet<IEngineRpcClient>();
            if (rpc == null) { TestStatus = "RPC service not available"; return; }

            var url = Prefs.EngineMode == "remote"
                ? Prefs.RemoteEngineUrl
                : $"ws://127.0.0.1:{Prefs.EnginePort}";

            // Quick probe: spin up a throwaway client; leaves the live one alone.
            using var probe = new EngineRpcClient();
            var ok = await probe.ConnectAsync(url);
            if (!ok) { TestStatus = "❌ Failed to connect"; return; }
            var caps = await new EditorApi(probe).GetCapabilitiesAsync();
            EngineVersion = caps?.Version ?? "-";
            TestStatus = $"✅ Guava Engine v{EngineVersion}";
            await probe.DisconnectAsync();
        }
        catch (Exception ex)
        {
            TestStatus = "❌ " + ex.Message;
        }
        finally { IsTesting = false; }
    }

    [RelayCommand]
    private async Task Reconnect()
    {
        var rpc = ServiceLocator.TryGet<IEngineRpcClient>();
        if (rpc == null) return;
        await rpc.DisconnectAsync();
        var url = Prefs.EngineMode == "remote"
            ? Prefs.RemoteEngineUrl
            : $"ws://127.0.0.1:{Prefs.EnginePort}";
        await rpc.ConnectAsync(url);
    }

    private static void ApplyTheme(string variant)
    {
        if (Application.Current is { } app)
        {
            app.RequestedThemeVariant = variant == "Light" ? ThemeVariant.Light : ThemeVariant.Dark;
        }
    }
}
