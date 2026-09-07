using System;
using System.IO;
using Windows.Storage;

namespace WindowsLlmHost.Gui.Services;

/// <summary>
/// Finds the windows-llm-host checkout (the folder containing docker-compose.yml).
/// Remembers the chosen path in packaged app settings.
/// </summary>
public sealed class RepoLocator
{
    private const string SettingKey = "RepoRoot";

    public string? GetSavedRoot()
    {
        var value = ApplicationData.Current.LocalSettings.Values[SettingKey] as string;
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    public void SaveRoot(string root)
    {
        ApplicationData.Current.LocalSettings.Values[SettingKey] = root;
    }

    /// <summary>Best guess at the repo root, or null if it cannot be found.</summary>
    public string? Resolve()
    {
        var saved = GetSavedRoot();
        if (saved != null && IsRepo(saved))
        {
            return saved;
        }

        var defaultPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "windows-llm-host");

        return IsRepo(defaultPath) ? defaultPath : null;
    }

    public static bool IsRepo(string? path) =>
        !string.IsNullOrWhiteSpace(path) && File.Exists(Path.Combine(path, "docker-compose.yml"));
}
