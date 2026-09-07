namespace WindowsLlmHost.Gui.Models;

/// <summary>
/// One installed model, as reported by `ollama list`.
/// </summary>
public sealed class OllamaModel
{
    public string Name { get; init; } = "";
    public string Id { get; init; } = "";
    public string Size { get; init; } = "";
    public string Modified { get; init; } = "";

    public string Details => string.IsNullOrWhiteSpace(Size) ? Id : $"{Size}  •  {Modified}";
}
