using System.Collections.Generic;
using System.Text.Json;
using System.Threading.Tasks;
using WindowsLlmHost.Gui.Models;

namespace WindowsLlmHost.Gui.Services;

/// <summary>
/// Wraps docker / docker compose for the windows-llm-host stack.
/// </summary>
public sealed class DockerService
{
    public const string OllamaContainer = "windows-llm-host-ollama";

    private readonly ProcessRunner _runner;
    private readonly string _repoRoot;

    public DockerService(ProcessRunner runner, string repoRoot)
    {
        _runner = runner;
        _repoRoot = repoRoot;
    }

    private Task<ProcessResult> ComposeAsync(params string[] args)
    {
        var list = new List<string> { "compose" };
        list.AddRange(args);
        return _runner.RunAsync("docker", list, _repoRoot);
    }

    public Task<ProcessResult> UpAsync() => ComposeAsync("up", "-d");
    public Task<ProcessResult> StopAsync() => ComposeAsync("stop");
    public Task<ProcessResult> StartAsync() => ComposeAsync("start");
    public Task<ProcessResult> DownAsync() => ComposeAsync("down");
    public Task<ProcessResult> RestartAsync() => ComposeAsync("restart");

    public Task<ProcessResult> LogsAsync(string service, int tail) =>
        ComposeAsync("logs", "--no-color", "--tail", tail.ToString(), service);

    /// <summary>Whether the `docker` CLI is reachable.</summary>
    public async Task<bool> IsDockerAvailableAsync()
    {
        var result = await _runner.RunAsync("docker", new[] { "version", "--format", "{{.Server.Version}}" }, _repoRoot);
        return result.Success;
    }

    public async Task<IReadOnlyList<ServiceStatus>> GetStatusAsync()
    {
        var result = await ComposeAsync("ps", "--format", "json");
        var list = new List<ServiceStatus>();
        var text = result.StdOut.Trim();
        if (!result.Success || text.Length == 0)
        {
            return list;
        }

        foreach (var json in SplitJson(text))
        {
            ServiceStatus? status = TryParseStatus(json);
            if (status != null)
            {
                list.Add(status);
            }
        }

        return list;
    }

    private static ServiceStatus? TryParseStatus(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            return new ServiceStatus
            {
                Service = GetStr(root, "Service"),
                Name = GetStr(root, "Name"),
                State = GetStr(root, "State"),
                Status = GetStr(root, "Status"),
                Health = GetStr(root, "Health"),
                Ports = FormatPublishers(root),
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }

    // docker compose v2 emits either a JSON array or one JSON object per line.
    private static IEnumerable<string> SplitJson(string text)
    {
        if (text.StartsWith('['))
        {
            using var doc = JsonDocument.Parse(text);
            foreach (var element in doc.RootElement.EnumerateArray())
            {
                yield return element.GetRawText();
            }
        }
        else
        {
            foreach (var line in text.Split('\n'))
            {
                var trimmed = line.Trim();
                if (trimmed.Length > 0)
                {
                    yield return trimmed;
                }
            }
        }
    }

    private static string GetStr(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? ""
            : "";

    private static string FormatPublishers(JsonElement root)
    {
        if (!root.TryGetProperty("Publishers", out var publishers) || publishers.ValueKind != JsonValueKind.Array)
        {
            return "";
        }

        var parts = new List<string>();
        foreach (var publisher in publishers.EnumerateArray())
        {
            var published = publisher.TryGetProperty("PublishedPort", out var pp) && pp.TryGetInt32(out var p) ? p : 0;
            var target = publisher.TryGetProperty("TargetPort", out var tp) && tp.TryGetInt32(out var t) ? t : 0;
            if (published > 0)
            {
                parts.Add($"{published}->{target}");
            }
        }

        return string.Join(", ", parts);
    }
}
