using System;
using Microsoft.UI.Xaml;

namespace WindowsLlmHost.Gui;

public sealed partial class MainWindow : Window
{
    /// <summary>HWND of this window, used to parent pickers/dialogs in WinUI 3 desktop.</summary>
    public static IntPtr WindowHandle { get; private set; }

    public MainWindow()
    {
        // The HWND exists once the Window object is constructed; capture it before
        // InitializeComponent creates MainPage (whose commands parent dialogs to it).
        WindowHandle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        this.InitializeComponent();
        Title = "windows-llm-host";
    }
}
