using System;
using Microsoft.UI.Xaml;
using WindowsLlmHost.Gui.ViewModels;

namespace WindowsLlmHost.Gui;

public sealed partial class MainWindow : Window
{
    /// <summary>HWND of this window, used to parent pickers/dialogs in WinUI 3 desktop.</summary>
    public static IntPtr WindowHandle { get; private set; }

    public MainViewModel ViewModel { get; } = new();

    public MainWindow()
    {
        this.InitializeComponent();
        WindowHandle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Title = "windows-llm-host";

        // Fire-and-forget: continuations marshal back to the UI thread via the
        // DispatcherQueue synchronization context installed for this window.
        _ = ViewModel.InitializeAsync();
    }
}
