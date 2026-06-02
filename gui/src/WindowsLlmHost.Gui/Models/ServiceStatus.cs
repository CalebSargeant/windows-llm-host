namespace WindowsLlmHost.Gui.Models;

/// <summary>
/// One row from `docker compose ps`, describing a stack container.
/// </summary>
public sealed class ServiceStatus
{
    public string Service { get; init; } = "";
    public string Name { get; init; } = "";
    public string State { get; init; } = "";
    public string Status { get; init; } = "";
    public string Health { get; init; } = "";
    public string Ports { get; init; } = "";

    public bool IsRunning =>
        string.Equals(State, "running", System.StringComparison.OrdinalIgnoreCase);

    /// <summary>Display string combining state and health for the UI.</summary>
    public string StateDisplay =>
        string.IsNullOrWhiteSpace(Health) ? State : $"{State} ({Health})";
}
