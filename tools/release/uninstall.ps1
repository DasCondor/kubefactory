# Removes KubeFactory for the current user.
#
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1             remove the program and shortcuts
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 -Purge      also remove your settings, audit logs and saved logs
param([switch]$Purge, [string]$Target = "")

# The Docker and Demo editions carry an EDITION file and install side by side with the full game.
$edition = (Get-Content (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "EDITION") -ErrorAction SilentlyContinue | Select-Object -First 1)
$app = if ($edition) { "KubeFactory $edition" } else { "KubeFactory" }
if (-not $Target) { $Target = Join-Path $env:LOCALAPPDATA "Programs\$app" }

if (Get-Process -Name "KubeFactory" -ErrorAction SilentlyContinue) {
    Write-Host "KubeFactory is running. Close it first." -ForegroundColor Red
    exit 1
}
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$app"
$desktop = Join-Path ([Environment]::GetFolderPath("Desktop")) "$app.lnk"
foreach ($p in @($startMenu, $desktop)) {
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
}
# This script may be running from inside the install folder, so step out first.
Set-Location $env:TEMP
if (Test-Path $Target) {
    Get-ChildItem $Target -Force | Where-Object { $_.Name -ne "uninstall.ps1" } | Remove-Item -Recurse -Force
    Remove-Item -Recurse -Force $Target -ErrorAction SilentlyContinue
}
if ($Purge) {
    $data = Join-Path $env:APPDATA "Godot\app_userdata\KubeFactory"
    if (Test-Path $data) { Remove-Item -Recurse -Force $data }
    Write-Host "Removed KubeFactory and your settings, audit logs and saved logs."
} else {
    Write-Host "Removed KubeFactory. Your settings and audit logs are still in %APPDATA%\Godot\app_userdata\KubeFactory (use -Purge to remove them)."
}
