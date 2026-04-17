using System;
using System.Globalization;
using Avalonia.Data.Converters;

namespace Guava.Editor.Markup;

/// <summary>
/// Converter that returns <c>true</c> when the bound value's string form equals
/// the converter parameter. Used for binding a single-select group of
/// RadioButtons to a string-valued property (section picker, mode picker).
/// </summary>
public sealed class EqualsConverter : IValueConverter
{
    public static readonly EqualsConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        return value?.ToString() == parameter?.ToString();
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        // Two-way binding: "true" means "set the source to the parameter value".
        if (value is bool b && b) return parameter;
        return Avalonia.Data.BindingOperations.DoNothing;
    }
}
