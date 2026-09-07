using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using WindowsLlmHost.Gui.Models;

namespace WindowsLlmHost.Gui.Services;

/// <summary>
/// Drives scripts/check-update.ps1 to report and apply updates.
/// </summary>
public sealed class UpdateService
{
    private readonly ProcessRunner _runner;
    private readonly string _repoRoot;

    public UpdateService(ProcessRunner runner, string repoRoot)
    {
        _runner = runner;
        _repoRoot = repoRoot;
    }

    private string ScriptPath => Path.Combine(_repoRoot, "scripts", "check-update.ps1");

    public async Task<UpdateStatus?> CheckAsync(string channel)
    {
        var result = await _runner.RunAsync(
            "powershell.exe",
            new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ScriptPath, "-Channel", channel, "-Json" },
            _repoRoot);

        // check-update.ps1 exits 10 when an update is available and 0 otherwise; both
        // print a single JSON object to stdout.
        var json = result.StdOut.Trim();
        if (json.Length == 0)
        {
            return null;
        }

        try
        {
            return JsonSerializer.Deserialize<UpdateStatus>(json);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public Task<ProcessResult> ApplyAsync(string channel) =>
        _runner.RunAsync(
            "powershell.exe",
            new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ScriptPath, "-Channel", channel, "-Update" },
            _repoRoot);
}
