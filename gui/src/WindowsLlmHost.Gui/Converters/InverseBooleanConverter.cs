using System;
using Microsoft.UI.Xaml.Data;

namespace WindowsLlmHost.Gui.Converters;

/// <summary>Negates a boolean. Handy for IsEnabled = not IsBusy.</summary>
public sealed class InverseBooleanConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        !(value is bool b && b);

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        !(value is bool b && b);
}
