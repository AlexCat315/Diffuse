using System;
using Avalonia.Data;
using Avalonia.Markup.Xaml;
using Guava.Editor.Services;

namespace Guava.Editor.Markup;

/// <summary>
/// Localization markup extension.  <Text>{loc:T menu.file.open}</Text>
///
/// Produces a one-way Binding to <see cref="I18nService.Instance"/> using the indexer,
/// so changing <see cref="I18nService.Language"/> automatically refreshes all bound text.
/// </summary>
public sealed class TExtension : MarkupExtension
{
    public string Key { get; set; } = string.Empty;

    public TExtension() { }
    public TExtension(string key) => Key = key;

    public override object ProvideValue(IServiceProvider serviceProvider)
    {
        return new Binding
        {
            Source = I18nService.Instance,
            Path = $"[{Key}]",
            Mode = BindingMode.OneWay,
        };
    }
}
