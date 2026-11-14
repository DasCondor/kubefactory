# Installs KubeFactory for the current user (no admin rights needed).
#
#   powershell -ExecutionPolicy Bypass -File install.ps1              install / upgrade
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Quiet       no prompts, no desktop shortcut (for IT rollout)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -ResetConfig also replace the config files with the shipped ones
#
# Installs to %LOCALAPPDATA%\Programs\KubeFactory and adds a Start Menu entry.
# On upgrade your edited config files (policy, app lists, log providers,
# Portainer link) are kept unless you pass -ResetConfig.
param([switch]$Quiet, [switch]$ResetConfig, [string]$Target = "")

$ErrorActionPreference = "Stop"
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Test-Path (Join-Path $src "KubeFactory.exe"))) {
    Write-Host "KubeFactory.exe is not next to this script. Run it from the unzipped release folder." -ForegroundColor Red
    exit 1
}
# The Docker and Demo editions carry an EDITION file and install side by side with the full game.
$edition = (Get-Content (Join-Path $src "EDITION") -ErrorAction SilentlyContinue | Select-Object -First 1)
$app = if ($edition) { "KubeFactory $edition" } else { "KubeFactory" }
if (-not $Target) { $Target = Join-Path $env:LOCALAPPDATA "Programs\$app" }
$version = (Get-Content (Join-Path $src "VERSION") -ErrorAction SilentlyContinue | Select-Object -First 1)

if (Get-Process -Name "KubeFactory" -ErrorAction SilentlyContinue) {
    Write-Host "KubeFactory is running. Close it and run the installer again." -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force $Target | Out-Null
$configs = @("policy.json", "catalogs.json", "log-providers.json", "portainer.json")
foreach ($item in Get-ChildItem $src) {
    $dest = Join-Path $Target $item.Name
    if ($configs -contains $item.Name -and (Test-Path $dest) -and -not $ResetConfig) {
        Write-Host ("  kept your  {0}" -f $item.Name)
        continue
    }
    if ($item.PSIsContainer) {
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        Copy-Item -Recurse $item.FullName $dest
    } else {
        Copy-Item -Force $item.FullName $dest
    }
}

$shell = New-Object -ComObject WScript.Shell
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$app"
New-Item -ItemType Directory -Force $startMenu | Out-Null
$links = @(@{ Name = $app; Args = "" })
if ($edition -ne "Demo") {
    if (-not $edition) { $links += @{ Name = "$app (simulation)"; Args = "-- --demo" } }
    $links += @{ Name = "$app (read-only)"; Args = "-- --read-only" }
}
foreach ($l in $links) {
    $lnk = $shell.CreateShortcut((Join-Path $startMenu ($l.Name + ".lnk")))
    $lnk.TargetPath = Join-Path $Target "KubeFactory.exe"
    $lnk.Arguments = $l.Args
    $lnk.WorkingDirectory = $Target
    $lnk.Save()
}
if (-not $Quiet) {
    $lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "$app.lnk"))
    $lnk.TargetPath = Join-Path $Target "KubeFactory.exe"
    $lnk.WorkingDirectory = $Target
    $lnk.Save()
}

Write-Host "`n$app $version installed to $Target" -ForegroundColor Cyan
if ($edition -eq "Docker" -and -not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "Note: docker was not found. Install Docker Desktop and start it; until then the game" -ForegroundColor Yellow
    Write-Host "      falls back to the built-in simulation." -ForegroundColor Yellow
}
if (-not $edition -and -not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "Note: kubectl was not found. The built-in simulation works without it; to manage real" -ForegroundColor Yellow
    Write-Host "      clusters run  check-requirements.ps1  in the install folder." -ForegroundColor Yellow
}
Write-Host "Start it from the Start Menu, or:  `"$Target\KubeFactory.exe`"`n"
