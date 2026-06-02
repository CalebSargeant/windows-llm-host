using System;
using System.IO;
using System.Threading.Tasks;

namespace WindowsLlmHost.Gui.Services;

/// <summary>
/// Checks for and adds the Windows Firewall rule that the stack uses for LAN access.
/// The rule name matches scripts/allow-firewall.ps1: "windows-llm-host API ($Port)".
/// </summary>
public sealed class FirewallService
{
    private readonly ProcessRunner _runner;
    private readonly string _repoRoot;

    public FirewallService(ProcessRunner runner, string repoRoot)
    {
        _runner = runner;
        _repoRoot = repoRoot;
    }

    public static string RuleName(int port) => $"windows-llm-host API ({port})";

    public async Task<bool> RuleExistsAsync(int port)
    {
        var result = await _runner.RunAsync(
            "netsh",
            new[] { "advfirewall", "firewall", "show", "rule", $"name={RuleName(port)}" });

        return result.Success &&
               result.StdOut.IndexOf("Rule Name", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    /// <summary>
    /// Runs allow-firewall.ps1. Adding a firewall rule needs elevation, so this is
    /// launched with the "runas" verb to prompt for UAC.
    /// </summary>
    public Task<ProcessResult> AllowAsync()
    {
        var script = Path.Combine(_repoRoot, "scripts", "allow-firewall.ps1");
        return _runner.RunAsync(
            "powershell.exe",
            new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script },
            _repoRoot);
    }
}
