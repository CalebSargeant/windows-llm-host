using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace WindowsLlmHost.Gui.Services;

/// <summary>
/// Reads and writes simple KEY=VALUE pairs in the repo's .env file, matching the
/// behaviour of the PowerShell helpers (Get-DotEnvValue / Set-DotEnvValue).
/// </summary>
public sealed class EnvFileService
{
    private readonly string _envPath;

    public EnvFileService(string repoRoot)
    {
        _envPath = Path.Combine(repoRoot, ".env");
    }

    public bool Exists => File.Exists(_envPath);

    public string Get(string name, string fallback = "")
    {
        if (!File.Exists(_envPath))
        {
            return fallback;
        }

        var pattern = new Regex($@"^\s*{Regex.Escape(name)}=(.*)$");
        foreach (var line in File.ReadAllLines(_envPath))
        {
            var match = pattern.Match(line);
            if (match.Success)
            {
                return match.Groups[1].Value.Trim().Trim('"');
            }
        }

        return fallback;
    }

    public void Set(string name, string value)
    {
        var lines = File.Exists(_envPath)
            ? File.ReadAllLines(_envPath).ToList()
            : new List<string>();

        var pattern = new Regex($@"^\s*{Regex.Escape(name)}=");
        var replaced = false;
        for (var i = 0; i < lines.Count; i++)
        {
            if (pattern.IsMatch(lines[i]))
            {
                lines[i] = $"{name}={value}";
                replaced = true;
                break;
            }
        }

        if (!replaced)
        {
            lines.Add($"{name}={value}");
        }

        File.WriteAllLines(_envPath, lines);
    }
}
