using System.IO;
using System.Threading.Tasks;

namespace WindowsLlmHost.Gui.Services;

/// <summary>
/// Drives scripts/game-mode-watcher.ps1 (status / install / uninstall scheduled task).
/// </summary>
public sealed class GameModeService
{
    private readonly ProcessRunner _runner;
    private readonly string _repoRoot;

    public GameModeService(ProcessRunner runner, string repoRoot)
    {
        _runner = runner;
        _repoRoot = repoRoot;
    }

    private string ScriptPath => Path.Combine(_repoRoot, "scripts", "game-mode-watcher.ps1");

    public Task<ProcessResult> StatusAsync() => Run("-Status");
    public Task<ProcessResult> InstallAsync() => Run("-Install");
    public Task<ProcessResult> UninstallAsync() => Run("-Uninstall");

    private Task<ProcessResult> Run(string switchArg) =>
        _runner.RunAsync(
            "powershell.exe",
            new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ScriptPath, switchArg },
            _repoRoot);
}
