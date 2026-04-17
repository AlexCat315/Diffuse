using System;
using System.IO;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Guava.Editor.State;

/// <summary>
/// Persistent editor preferences. Lives in <c>~/Library/Application Support/
/// Guava/editor-prefs.json</c> on macOS (and the XDG equivalent elsewhere).
///
/// Kept deliberately small. Per-panel ephemeral state stays in each VM; only
/// truly app-global toggles belong here.
/// </summary>
public sealed partial class AppPreferencesStore : ObservableObject
{
    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    [ObservableProperty] private string _language = "en";
    [ObservableProperty] private string _themeVariant = "Dark";   // "Dark" | "Light"
    [ObservableProperty] private bool _showFps = true;
    [ObservableProperty] private int _maxConsoleLogs = 1000;
    [ObservableProperty] private string _engineMode = "local";     // "local" | "remote"
    [ObservableProperty] private string _remoteEngineUrl = "ws://192.168.1.100:9100";
    [ObservableProperty] private int _enginePort = 9100;

    private string? _path;
    private bool _loading;

    public static AppPreferencesStore Load()
    {
        var store = new AppPreferencesStore();
        store._path = ResolvePath();

        try
        {
            if (File.Exists(store._path))
            {
                var json = File.ReadAllText(store._path);
                var dto = JsonSerializer.Deserialize<Dto>(json);
                if (dto != null)
                {
                    store._loading = true;
                    store.Language         = dto.Language ?? store.Language;
                    store.ThemeVariant     = dto.ThemeVariant ?? store.ThemeVariant;
                    store.ShowFps          = dto.ShowFps ?? store.ShowFps;
                    store.MaxConsoleLogs   = dto.MaxConsoleLogs ?? store.MaxConsoleLogs;
                    store.EngineMode       = dto.EngineMode ?? store.EngineMode;
                    store.RemoteEngineUrl  = dto.RemoteEngineUrl ?? store.RemoteEngineUrl;
                    store.EnginePort       = dto.EnginePort ?? store.EnginePort;
                    store._loading = false;
                }
            }
        }
        catch { /* best-effort — first-run or corrupt file falls back to defaults */ }

        store.PropertyChanged += (_, _) => store.Save();
        return store;
    }

    public void Save()
    {
        if (_loading || _path == null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var dto = new Dto
            {
                Language = Language,
                ThemeVariant = ThemeVariant,
                ShowFps = ShowFps,
                MaxConsoleLogs = MaxConsoleLogs,
                EngineMode = EngineMode,
                RemoteEngineUrl = RemoteEngineUrl,
                EnginePort = EnginePort,
            };
            File.WriteAllText(_path, JsonSerializer.Serialize(dto, JsonOpts));
        }
        catch { /* disk full etc. — not worth surfacing */ }
    }

    private static string ResolvePath()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData,
                                                Environment.SpecialFolderOption.Create);
        if (string.IsNullOrEmpty(baseDir))
        {
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        }
        return Path.Combine(baseDir, "Guava", "editor-prefs.json");
    }

    private sealed class Dto
    {
        public string? Language { get; set; }
        public string? ThemeVariant { get; set; }
        public bool? ShowFps { get; set; }
        public int? MaxConsoleLogs { get; set; }
        public string? EngineMode { get; set; }
        public string? RemoteEngineUrl { get; set; }
        public int? EnginePort { get; set; }
    }
}
