using System.Text.Json.Serialization;

namespace WindowsLlmHost.Gui.Models;

/// <summary>
/// Mirrors the JSON emitted by scripts/check-update.ps1 -Json.
/// </summary>
public sealed class UpdateStatus
{
    [JsonPropertyName("channel")]
    public string Channel { get; set; } = "";

    [JsonPropertyName("current")]
    public string? Current { get; set; }

    [JsonPropertyName("latest")]
    public string? Latest { get; set; }

    [JsonPropertyName("updateAvailable")]
    public bool UpdateAvailable { get; set; }

    [JsonPropertyName("detail")]
    public string Detail { get; set; } = "";
}
