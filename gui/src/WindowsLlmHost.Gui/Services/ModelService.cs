using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using WindowsLlmHost.Gui.Models;

namespace WindowsLlmHost.Gui.Services;

/// <summary>
/// Lists, pulls, and removes Ollama models via `docker exec ... ollama`.
/// </summary>
public sealed class ModelService
{
    private readonly ProcessRunner _runner;
    private readonly string _repoRoot;

    public ModelService(ProcessRunner runner, string repoRoot)
    {
        _runner = runner;
        _repoRoot = repoRoot;
    }

    public async Task<IReadOnlyList<OllamaModel>> ListAsync()
    {
        var result = await _runner.RunAsync(
            "docker",
            new[] { "exec", DockerService.OllamaContainer, "ollama", "list" },
            _repoRoot);

        var models = new List<OllamaModel>();
        if (!result.Success)
        {
            return models;
        }

        var lines = result.StdOut.Split('\n');
        // Skip the header row (NAME ID SIZE MODIFIED).
        for (var i = 1; i < lines.Length; i++)
        {
            var line = lines[i].Trim();
            if (line.Length == 0)
            {
                continue;
            }

            // Columns are separated by runs of 2+ spaces (or tabs); keeps "4.7 GB" intact.
            var cols = Regex.Split(line, @"\s{2,}|\t+");
            if (cols.Length == 0 || cols[0].Length == 0)
            {
                continue;
            }

            models.Add(new OllamaModel
            {
                Name = cols[0].Trim(),
                Id = cols.Length > 1 ? cols[1].Trim() : "",
                Size = cols.Length > 2 ? cols[2].Trim() : "",
                Modified = cols.Length > 3 ? cols[3].Trim() : "",
            });
        }

        return models;
    }

    public Task<ProcessResult> PullAsync(string name) =>
        _runner.RunAsync("docker", new[] { "exec", DockerService.OllamaContainer, "ollama", "pull", name }, _repoRoot);

    public Task<ProcessResult> RemoveAsync(string name) =>
        _runner.RunAsync("docker", new[] { "exec", DockerService.OllamaContainer, "ollama", "rm", name }, _repoRoot);
}
