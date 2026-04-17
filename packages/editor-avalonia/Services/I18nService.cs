using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Text.Json;
using Avalonia;
using Avalonia.Platform;

namespace Guava.Editor.Services;

/// <summary>
/// Flat-key i18n service. Single instance, reactive via INotifyPropertyChanged.
///
/// Usage in XAML:      Text="{loc:T menu.file.open}"
/// Usage in code:      I18nService.Instance["menu.file.open"]
/// Change language:    I18nService.Instance.Language = "zh";
///
/// Resource files live at avares://Guava.Editor/Assets/Locales/{lang}.json and may be
/// nested objects — they are flattened on load using dot-separated paths.
/// Missing keys fall back to the key string itself (aids development visibility).
/// </summary>
public sealed class I18nService : INotifyPropertyChanged
{
    private static readonly Lazy<I18nService> _instance = new(() => new I18nService());
    public static I18nService Instance => _instance.Value;

    private readonly Dictionary<string, string> _strings = new(StringComparer.Ordinal);
    private string _language = "en";

    public event PropertyChangedEventHandler? PropertyChanged;

    public IReadOnlyList<string> AvailableLanguages { get; } = new[] { "en", "zh" };

    public string Language
    {
        get => _language;
        set
        {
            if (_language == value) return;
            _language = value;
            LoadLanguage(value);
            // Empty-string property name refreshes every binding on this instance.
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
        }
    }

    public string this[string key] => _strings.TryGetValue(key, out var v) ? v : key;

    public string Get(string key, string fallback) =>
        _strings.TryGetValue(key, out var v) ? v : fallback;

    private I18nService()
    {
        LoadLanguage(_language);
    }

    private void LoadLanguage(string lang)
    {
        _strings.Clear();
        var uri = new Uri($"avares://Guava.Editor/Assets/Locales/{lang}.json");
        try
        {
            using var stream = AssetLoader.Open(uri);
            using var doc = JsonDocument.Parse(stream);
            Flatten(doc.RootElement, prefix: string.Empty, _strings);
        }
        catch (FileNotFoundException)
        {
            // Unknown language — leave empty so keys are echoed back.
        }
    }

    private static void Flatten(JsonElement element, string prefix, Dictionary<string, string> target)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var prop in element.EnumerateObject())
                {
                    var key = prefix.Length == 0 ? prop.Name : $"{prefix}.{prop.Name}";
                    Flatten(prop.Value, key, target);
                }
                break;
            case JsonValueKind.String:
                target[prefix] = element.GetString() ?? string.Empty;
                break;
            case JsonValueKind.Number:
            case JsonValueKind.True:
            case JsonValueKind.False:
                target[prefix] = element.ToString();
                break;
            // Arrays, Null, Undefined: ignored.
        }
    }
}
