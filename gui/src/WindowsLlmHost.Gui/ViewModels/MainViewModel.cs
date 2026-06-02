using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;
using WindowsLlmHost.Gui.Models;
using WindowsLlmHost.Gui.Services;

namespace WindowsLlmHost.Gui.ViewModels;

/// <summary>
/// Backing view model for MainWindow. Orchestrates the stack via the service layer.
/// All command methods route through <see cref="RunBusyAsync"/> so only one Docker /
/// script operation runs at a time and the UI shows a busy state.
/// </summary>
public partial class MainViewModel : ObservableObject
{
    private readonly ProcessRunner _runner = new();
    private readonly RepoLocator _repoLocator = new();

    private DockerService? _docker;
    private EnvFileService? _env;
    private ModelService? _models;
    private UpdateService? _update;
    private GameModeService? _gameMode;
    private FirewallService? _firewall;

    public ObservableCollection<ServiceStatus> Services { get; } = new();
    public ObservableCollection<OllamaModel> Models { get; } = new();
    public string[] LogServices { get; } = { "ollama", "api", "open-webui" };
    public string[] UpdateChannels { get; } = { "stable", "prerelease", "main" };

    [ObservableProperty] private string _repoRoot = "";
    [ObservableProperty] private bool _isRepoValid;
    [ObservableProperty] private string _repoStatus = "Locating windows-llm-host checkout...";

    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _busyMessage = "";
    [ObservableProperty] private string _lastMessage = "";

    [ObservableProperty] private bool _stackRunning;

    [ObservableProperty] private string _apiBaseUrl = "";
    [ObservableProperty] private string _lanApiUrl = "";
    [ObservableProperty] private string _apiPort = "11434";
    [ObservableProperty] private string _apiKey = "";
    [ObservableProperty] private bool _lanEnabled;
    [ObservableProperty] private bool _firewallOk;

    [ObservableProperty] private string _webUiUrl = "";
    [ObservableProperty] private bool _webUiExposed;
    [ObservableProperty] private bool _webUiAuth;

    [ObservableProperty] private string _newModelName = "";
    [ObservableProperty] private OllamaModel? _selectedModel;

    [ObservableProperty] private string _selectedLogService = "api";
    [ObservableProperty] private string _logText = "";

    [ObservableProperty] private string _updateChannel = "stable";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(VersionSummary))]
    private string _installedVersion = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(VersionSummary))]
    private string _latestVersion = "";

    [ObservableProperty] private bool _updateAvailable;
    [ObservableProperty] private string _updateDetail = "";

    [ObservableProperty] private string _gameModeStatus = "";

    public string VersionSummary => $"Installed: {InstalledVersion}     Latest: {LatestVersion}";

    /// <summary>Called once when the window loads.</summary>
    public async Task InitializeAsync()
    {
        var root = _repoLocator.Resolve();
        if (root == null)
        {
            IsRepoValid = false;
            RepoStatus = "Could not find a windows-llm-host checkout. Click 'Choose folder' and select the folder that contains docker-compose.yml.";
            return;
        }

        SetRepoRoot(root);
        await RefreshAllInternalAsync();
    }

    private void SetRepoRoot(string root)
    {
        RepoRoot = root;
        _repoLocator.SaveRoot(root);

        _docker = new DockerService(_runner, root);
        _env = new EnvFileService(root);
        _models = new ModelService(_runner, root);
        _update = new UpdateService(_runner, root);
        _gameMode = new GameModeService(_runner, root);
        _firewall = new FirewallService(_runner, root);

        IsRepoValid = true;
        RepoStatus = $"Using checkout at {root}";
        LoadConnectionInfo();
    }

    private void LoadConnectionInfo()
    {
        if (_env == null)
        {
            return;
        }

        var bind = _env.Get("API_BIND", "0.0.0.0");
        ApiPort = _env.Get("API_PORT", "11434");
        var host = bind == "0.0.0.0" ? "localhost" : bind;
        ApiBaseUrl = $"http://{host}:{ApiPort}";
        LanApiUrl = bind == "0.0.0.0" ? $"http://<this-laptop-ip>:{ApiPort}" : "(LAN binding disabled)";
        ApiKey = _env.Get("LLM_HOST_API_KEY", "");
        LanEnabled = bind == "0.0.0.0";

        var webBind = _env.Get("WEBUI_BIND", "127.0.0.1");
        var webPort = _env.Get("WEBUI_PORT", "3000");
        var webHost = webBind == "0.0.0.0" ? "<this-laptop-ip>" : "localhost";
        WebUiUrl = $"http://{webHost}:{webPort}";
        WebUiExposed = webBind == "0.0.0.0";
        WebUiAuth = string.Equals(_env.Get("WEBUI_AUTH", "false"), "true", StringComparison.OrdinalIgnoreCase);
    }

    private async Task RunBusyAsync(string message, Func<Task> action)
    {
        if (IsBusy)
        {
            LastMessage = "Busy - please wait for the current operation to finish.";
            return;
        }

        if (!IsRepoValid)
        {
            LastMessage = "Set a valid windows-llm-host folder first.";
            return;
        }

        IsBusy = true;
        BusyMessage = message;
        LastMessage = message;
        try
        {
            await action();
        }
        catch (Exception ex)
        {
            LastMessage = $"Error: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
            BusyMessage = "";
        }
    }

    // --- Repo selection ---------------------------------------------------------

    [RelayCommand]
    private async Task PickRepo()
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, MainWindow.WindowHandle);

        var folder = await picker.PickSingleFolderAsync();
        if (folder == null)
        {
            return;
        }

        if (!RepoLocator.IsRepo(folder.Path))
        {
            RepoStatus = $"{folder.Path} does not contain docker-compose.yml.";
            return;
        }

        SetRepoRoot(folder.Path);
        await RefreshAllInternalAsync();
    }

    // --- Status / lifecycle -----------------------------------------------------

    private async Task RefreshStatusInternalAsync()
    {
        if (_docker == null)
        {
            return;
        }

        var services = await _docker.GetStatusAsync();
        Services.Clear();
        foreach (var service in services)
        {
            Services.Add(service);
        }

        StackRunning = services.Any(s => s.IsRunning);
    }

    private async Task RefreshAllInternalAsync()
    {
        await RefreshStatusInternalAsync();
        await RefreshModelsInternalAsync();
        await RefreshFirewallAsync();
    }

    [RelayCommand]
    private Task RefreshAll() => RunBusyAsync("Refreshing...", RefreshAllInternalAsync);

    [RelayCommand]
    private Task RefreshStatus() => RunBusyAsync("Refreshing status...", RefreshStatusInternalAsync);

    [RelayCommand]
    private Task StartStack() => RunBusyAsync("Starting stack...", async () =>
    {
        var result = await _docker!.UpAsync();
        LastMessage = result.Success ? "Stack started." : result.Combined;
        await RefreshStatusInternalAsync();
    });

    [RelayCommand]
    private Task StopStack() => RunBusyAsync("Stopping stack...", async () =>
    {
        var result = await _docker!.StopAsync();
        LastMessage = result.Success ? "Stack stopped (containers kept)." : result.Combined;
        await RefreshStatusInternalAsync();
    });

    [RelayCommand]
    private Task RestartStack() => RunBusyAsync("Restarting stack...", async () =>
    {
        var result = await _docker!.RestartAsync();
        LastMessage = result.Success ? "Stack restarted." : result.Combined;
        await RefreshStatusInternalAsync();
    });

    [RelayCommand]
    private Task DownStack() => RunBusyAsync("Stopping and removing containers...", async () =>
    {
        var result = await _docker!.DownAsync();
        LastMessage = result.Success ? "Containers removed (models and data kept)." : result.Combined;
        await RefreshStatusInternalAsync();
    });

    // --- Connection -------------------------------------------------------------

    [RelayCommand]
    private void CopyApiKey() => CopyToClipboard(ApiKey, "API key copied to clipboard.");

    [RelayCommand]
    private void CopyBaseUrl() => CopyToClipboard(ApiBaseUrl, "Base URL copied to clipboard.");

    private void CopyToClipboard(string text, string okMessage)
    {
        if (string.IsNullOrEmpty(text))
        {
            LastMessage = "Nothing to copy.";
            return;
        }

        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        LastMessage = okMessage;
    }

    [RelayCommand]
    private Task ToggleLan() => RunBusyAsync("Applying network binding...", async () =>
    {
        var current = _env!.Get("API_BIND", "0.0.0.0");
        var newBind = current == "0.0.0.0" ? "127.0.0.1" : "0.0.0.0";
        _env.Set("API_BIND", newBind);

        var result = await _docker!.UpAsync();
        LoadConnectionInfo();
        LastMessage = result.Success
            ? $"API now binds to {newBind}; containers recreated."
            : result.Combined;

        if (newBind == "0.0.0.0")
        {
            await RefreshFirewallAsync();
        }
    });

    private async Task RefreshFirewallAsync()
    {
        if (_firewall == null)
        {
            return;
        }

        if (int.TryParse(ApiPort, out var port))
        {
            FirewallOk = await _firewall.RuleExistsAsync(port);
        }
    }

    [RelayCommand]
    private Task AllowFirewall() => RunBusyAsync("Adding firewall rule (may prompt for admin)...", async () =>
    {
        var result = await _firewall!.AllowAsync();
        await RefreshFirewallAsync();
        LastMessage = result.Success
            ? "Firewall rule added (or already present)."
            : $"Firewall step returned: {result.Combined}";
    });

    // --- Models -----------------------------------------------------------------

    private async Task RefreshModelsInternalAsync()
    {
        if (_models == null)
        {
            return;
        }

        var models = await _models.ListAsync();
        Models.Clear();
        foreach (var model in models)
        {
            Models.Add(model);
        }
    }

    [RelayCommand]
    private Task RefreshModels() => RunBusyAsync("Listing models...", RefreshModelsInternalAsync);

    [RelayCommand]
    private Task PullModel() => RunBusyAsync($"Pulling {NewModelName}... (large models take a while)", async () =>
    {
        if (string.IsNullOrWhiteSpace(NewModelName))
        {
            LastMessage = "Enter a model name first, e.g. qwen3:4b-instruct.";
            return;
        }

        var name = NewModelName.Trim();
        var result = await _models!.PullAsync(name);
        LastMessage = result.Success ? $"Pulled {name}." : result.Combined;
        await RefreshModelsInternalAsync();
    });

    [RelayCommand]
    private Task RemoveModel() => RunBusyAsync("Removing model...", async () =>
    {
        if (SelectedModel == null)
        {
            LastMessage = "Select a model to remove.";
            return;
        }

        var name = SelectedModel.Name;
        var result = await _models!.RemoveAsync(name);
        LastMessage = result.Success ? $"Removed {name}." : result.Combined;
        await RefreshModelsInternalAsync();
    });

    // --- Logs -------------------------------------------------------------------

    [RelayCommand]
    private Task RefreshLogs() => RunBusyAsync($"Loading {SelectedLogService} logs...", async () =>
    {
        var result = await _docker!.LogsAsync(SelectedLogService, 200);
        LogText = result.Success ? result.StdOut : result.Combined;
    });

    // --- Updates ----------------------------------------------------------------

    private async Task CheckUpdateInternalAsync()
    {
        var status = await _update!.CheckAsync(UpdateChannel);
        if (status == null)
        {
            LastMessage = "Update check failed or returned no data.";
            return;
        }

        InstalledVersion = status.Current ?? "unknown";
        LatestVersion = status.Latest ?? "(none)";
        UpdateAvailable = status.UpdateAvailable;
        UpdateDetail = status.Detail;
        LastMessage = status.Detail;
    }

    [RelayCommand]
    private Task CheckUpdate() => RunBusyAsync("Checking for updates...", CheckUpdateInternalAsync);

    [RelayCommand]
    private Task ApplyUpdate() => RunBusyAsync("Applying update (this can take a while)...", async () =>
    {
        var result = await _update!.ApplyAsync(UpdateChannel);
        LastMessage = result.Success
            ? "Update applied. Restart the app if its scripts changed."
            : result.Combined;
        await CheckUpdateInternalAsync();
    });

    // --- Game Mode --------------------------------------------------------------

    [RelayCommand]
    private Task RefreshGameMode() => RunBusyAsync("Reading Game Mode status...", async () =>
    {
        var result = await _gameMode!.StatusAsync();
        GameModeStatus = result.Combined;
    });

    [RelayCommand]
    private Task InstallGameMode() => RunBusyAsync("Installing Game Mode watcher...", async () =>
    {
        var result = await _gameMode!.InstallAsync();
        GameModeStatus = result.Combined;
        LastMessage = result.Success ? "Game Mode watcher installed." : result.Combined;
    });

    [RelayCommand]
    private Task UninstallGameMode() => RunBusyAsync("Removing Game Mode watcher...", async () =>
    {
        var result = await _gameMode!.UninstallAsync();
        GameModeStatus = result.Combined;
        LastMessage = result.Success ? "Game Mode watcher removed." : result.Combined;
    });

    // --- Open WebUI -------------------------------------------------------------

    [RelayCommand]
    private Task SaveWebUiSettings() => RunBusyAsync("Applying Open WebUI settings...", async () =>
    {
        _env!.Set("WEBUI_BIND", WebUiExposed ? "0.0.0.0" : "127.0.0.1");
        _env.Set("WEBUI_AUTH", WebUiAuth ? "true" : "false");
        if (WebUiExposed)
        {
            // Turning on auth + API keys is the safe posture when exposing to the LAN.
            _env.Set("ENABLE_API_KEYS", WebUiAuth ? "true" : "false");
            _env.Set("USER_PERMISSIONS_FEATURES_API_KEYS", WebUiAuth ? "true" : "false");
        }

        var result = await _docker!.UpAsync();
        LoadConnectionInfo();
        LastMessage = result.Success ? "Open WebUI settings applied; containers recreated." : result.Combined;
    });
}
