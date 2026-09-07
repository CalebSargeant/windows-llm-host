using Microsoft.UI.Xaml;

namespace WindowsLlmHost.Gui;

/// <summary>
/// Application entry point. Creates and activates the main window.
/// </summary>
public partial class App : Application
{
    private Window? _window;

    public App()
    {
        this.InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }
}
