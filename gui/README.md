# windows-llm-host GUI

A Windows desktop app (WinUI 3 / Windows App SDK, .NET 8, packaged as MSIX) for managing a local windows-llm-host stack: start/stop, models, API key, updates, Game Mode, and Open WebUI exposure.

It is a thin, full-trust front end over the same things you would otherwise do from PowerShell: it shells out to `docker` / `docker compose` and to the repo's scripts (`check-update.ps1`, `game-mode-watcher.ps1`, `allow-firewall.ps1`). It does not reimplement that logic, so the GUI and the CLI stay in sync.

> Status: this app was authored on macOS. It **builds and packages into an MSIX in CI** on `windows-latest` via the `GUI build (MSIX)` workflow (`.github/workflows/gui-build.yml`) — that is the build gate. It has **not yet been run interactively** on Windows, so expect to polish UI and behaviour on first use. The framework-independent service/model code is also compile-checked with `dotnet build` against net9.0.

## What it does

- **Stack**: start / stop / restart / down, with live container status (from `docker compose ps`).
- **Connection**: shows the API base URL and `LLM_HOST_API_KEY` with copy buttons; toggles LAN vs local-only binding; shows and adds the Windows Firewall rule.
- **Models**: lists installed models (`ollama list`), pulls a model by name, removes the selected model.
- **Logs**: tails the last 200 lines for `ollama`, `api`, or `open-webui`.
- **Updates**: checks `main` / `stable` / `prerelease` via `check-update.ps1 -Json` and can apply an update.
- **Game Mode**: shows status and installs/removes the Game Mode watcher scheduled task.
- **Open WebUI**: toggles LAN exposure and the auth/API-key posture, then recreates the containers.

## Project layout

```
gui/
  WindowsLlmHost.Gui.sln
  src/WindowsLlmHost.Gui/
    App.xaml(.cs)              app entry point
    MainWindow.xaml(.cs)       host window (hosts MainPage)
    MainPage.xaml(.cs)         the UI (a Page, so x:Bind compiled bindings work)
    Package.appxmanifest       MSIX manifest (identity, capabilities, tiles)
    app.manifest               DPI awareness, supported OS
    Models/                    plain data types (ServiceStatus, OllamaModel, UpdateStatus)
    Services/                  ProcessRunner + Docker/Env/Model/Update/GameMode/Firewall/RepoLocator
    ViewModels/MainViewModel   MVVM glue (CommunityToolkit.Mvvm)
    Converters/                XAML value converters
    Assets/                    MSIX logos (placeholders, see below)
  tools/generate-placeholder-assets.py
```

## Prerequisites

- Windows 10 (build 17763+) or Windows 11.
- Visual Studio 2022 with these workloads/components:
  - **.NET Desktop Development**
  - **Windows application development** (includes the Windows App SDK / WinUI tooling)
  - the **.NET 8 SDK** and a recent **Windows 11 SDK**
- Docker Desktop (the app manages the stack but does not install Docker).

You can also build from the command line with the .NET 8 SDK + MSBuild (see below).

## Build and run

In Visual Studio: open `gui/WindowsLlmHost.Gui.sln`, set `WindowsLlmHost.Gui` as the startup project, pick `x64` (or `ARM64`), and press F5. The app deploys as a packaged app and launches.

From the command line:

```powershell
# Restore + build (Debug) for x64
msbuild gui\WindowsLlmHost.Gui.sln /t:Restore /p:Configuration=Debug /p:Platform=x64
msbuild gui\WindowsLlmHost.Gui.sln /p:Configuration=Debug /p:Platform=x64
```

On first launch the app looks for your checkout at `%USERPROFILE%\windows-llm-host` (the folder containing `docker-compose.yml`). If it is elsewhere, click **Choose folder**; the path is remembered.

## Placeholder assets

`src/WindowsLlmHost.Gui/Assets/*.png` are solid-color placeholders so the MSIX builds. Replace them with real branded artwork before publishing. To regenerate the placeholders:

```bash
python3 gui/tools/generate-placeholder-assets.py
```

## Package an MSIX

The CI workflow produces an unsigned MSIX on every push that touches `gui/`. To build one locally:

```powershell
msbuild gui\WindowsLlmHost.Gui.sln `
  /p:Configuration=Release /p:Platform=x64 `
  /p:GenerateAppxPackageOnBuild=true `
  /p:AppxPackageSigningEnabled=false `
  /p:UapAppxPackageBuildMode=SideloadOnly `
  /p:AppxPackageDir=$PWD\artifacts\
```

The `.msix` lands under `artifacts\`.

## Sign for sideloading (test installs)

An MSIX must be signed to install outside the Store. For local testing, create a self-signed cert whose subject matches `Publisher` in `Package.appxmanifest` (`CN=CalebSargeant`):

```powershell
$cert = New-SelfSignedCertificate -Type Custom -Subject "CN=CalebSargeant" `
  -KeyUsage DigitalSignature -FriendlyName "windows-llm-host dev" `
  -CertStoreLocation "Cert:\CurrentUser\My" `
  -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")

# Export and trust it (run the import elevated; trusting a cert is a security decision):
$pwd = ConvertTo-SecureString -String "choose-a-password" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath windows-llm-host-dev.pfx -Password $pwd
Import-PfxCertificate -FilePath windows-llm-host-dev.pfx -Password $pwd `
  -CertStoreLocation Cert:\LocalMachine\TrustedPeople
```

Then sign (signtool ships with the Windows SDK):

```powershell
signtool sign /fd SHA256 /a /f windows-llm-host-dev.pfx /p "choose-a-password" `
  artifacts\<package>.msix
```

Install by double-clicking the `.msix`, or:

```powershell
Add-AppxPackage artifacts\<package>.msix
```

Never commit the `.pfx`/`.cer`; they are git-ignored.

## Publish to the Microsoft Store

1. In **Partner Center** (Windows & Xbox), reserve the app name and create the app listing.
2. From the app's **Product identity** page, note the **Package/Identity/Name**, **Publisher**, and **Publisher display name**.
3. Put those values into `Package.appxmanifest` (`Identity Name`, `Identity Publisher`, `Properties/PublisherDisplayName`). In Visual Studio you can instead use **Project ▸ Publish ▸ Associate App with the Store**, which fills these in for you.
4. Build the upload package: **Project ▸ Publish ▸ Create App Packages ▸ Microsoft Store**, which produces an `.msixupload`. (Store packages are signed by the Store, so you do not sign them yourself.)
5. Upload the `.msixupload` in Partner Center, complete the submission (age rating, privacy, etc.), and submit for certification.

Notes:
- The app declares the `runFullTrust` restricted capability because it launches `docker`, `git`, and PowerShell. Full-trust desktop apps are allowed in the Store but the listing must explain why; Store certification may take longer for full-trust apps.
- Consider shipping per-architecture packages (x64 + ARM64) in a single submission.

## CI

`.github/workflows/gui-build.yml` builds the solution and produces an unsigned MSIX artifact on `windows-latest` for pushes/PRs touching `gui/`, and via manual dispatch. Use it as the source of truth for "does this compile on Windows" until the app has been built locally.

## Known limitations / TODO

- Model pulls run to completion before reporting; no live progress bar yet.
- Adding the firewall rule needs elevation; if the app is not elevated, the rule step may fail and you will be told to run `scripts/allow-firewall.ps1` from an elevated PowerShell.
- No tray icon / background mode yet; this is a foreground window. A tray + autostart mode is a natural next iteration.
- Replace placeholder Assets with real artwork before any Store submission.
