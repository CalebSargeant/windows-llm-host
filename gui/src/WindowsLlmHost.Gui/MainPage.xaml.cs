using Microsoft.UI.Xaml.Controls;
using WindowsLlmHost.Gui.ViewModels;

namespace WindowsLlmHost.Gui;

/// <summary>
/// Hosts the whole UI. This is a Page (a FrameworkElement) so x:Bind compiled
/// bindings work - a Window root cannot host x:Bind directly.
/// </summary>
public sealed partial class MainPage : Page
{
    public MainViewModel ViewModel { get; } = new();

    public MainPage()
    {
        this.InitializeComponent();

        // Continuations marshal back to the UI thread via the DispatcherQueue
        // synchronization context installed for this thread.
        _ = ViewModel.InitializeAsync();
    }
}
