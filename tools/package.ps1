# Builds the deployable release:
#
#   dist\KubeFactory-<version>-win64.zip          what you hand out / publish
#   dist\KubeFactory-<version>-win64.zip.sha256   its checksum
#
# The zip is flat: the docs, config files and helper scripts that live in docs\, config\ and
# tools\ here all sit beside KubeFactory.exe in it.
#
# The zip holds a standalone KubeFactory.exe (no engine or source needed), the
# editable config files, the bundled app setups, the cluster setup manifest, an
# installer and an uninstaller.
#
#   powershell -ExecutionPolicy Bypass -File tools\package.ps1                    the full game
#   powershell -ExecutionPolicy Bypass -File tools\package.ps1 -Edition docker    KubeFactory Docker: opens on the local Docker engine, no kubectl
#   powershell -ExecutionPolicy Bypass -File tools\package.ps1 -Edition demo      KubeFactory Demo: the full game on the simulated clusters only
#
# An edition builds dist\KubeFactory-<Edition>-<version>-win64.zip from its own
# export preset and installs side by side with the full game.
#
# Needs the Godot export templates for the engine version in .\engine
# (%APPDATA%\Godot\export_templates\4.3.stable).
param([ValidateSet("", "docker", "demo")][string]$Edition = "")
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# In the source tree this script lives in tools\; in a release zip it sits beside KubeFactory.exe.
$root = if (Test-Path (Join-Path $here "..\project.godot")) { (Resolve-Path (Join-Path $here "..")).Path } else { $here }
$godot = Join-Path $root "engine\Godot_v4.3-stable_win64_console.exe"
$version = (Select-String -Path (Join-Path $root "scripts\main.gd") -Pattern 'const VERSION = "(.+)"').Matches[0].Groups[1].Value
$label = if ($Edition) { $Edition.Substring(0, 1).ToUpper() + $Edition.Substring(1) } else { "" }
$preset = if ($Edition) { "Windows $label" } else { "Windows Desktop" }
$name = if ($Edition) { "KubeFactory-$label-$version-win64" } else { "KubeFactory-$version-win64" }
$stage = Join-Path $root "dist\$name"
$zip = "$stage.zip"

$tpl = Join-Path $env:APPDATA "Godot\export_templates\4.3.stable\windows_release_x86_64.exe"
if (-not (Test-Path $tpl)) {
    Write-Host "Export templates not found at $tpl" -ForegroundColor Red
    Write-Host "Download Godot_v4.3-stable_export_templates.tpz from the Godot 4.3 release page and"
    Write-Host "extract its windows_*_x86_64*.exe files and version.txt into that folder."
    exit 1
}

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
if (Test-Path $zip) { Remove-Item -Force $zip }
New-Item -ItemType Directory -Force $stage | Out-Null

Write-Host "Running tests..."
$ErrorActionPreference = "Continue"
& $godot --headless --path $root -s tests/normalize_test.gd 2>$null | Select-Object -Last 1 | Tee-Object -Variable testResult
if ($testResult -notmatch "ALL CHECKS PASSED") { Write-Host "Tests failed; not packaging." -ForegroundColor Red; exit 1 }

Write-Host "Exporting KubeFactory.exe..."
& $godot --headless --path $root --export-release $preset (Join-Path $stage "KubeFactory.exe") 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
if (-not (Test-Path (Join-Path $stage "KubeFactory.exe"))) { Write-Host "Export failed." -ForegroundColor Red; exit 1 }

foreach ($f in @("README.md", "LICENSE", "docs\ADMIN.md", "docs\THIRDPARTY.md", "docs\SECURITY.md", "config\catalogs.json", "config\portainer.json", "config\log-providers.json", "config\policy.json", "config\bob.json")) {
    Copy-Item (Join-Path $root $f) $stage
}
Copy-Item -Recurse (Join-Path $root "tools\dev") (Join-Path $stage "dev")
foreach ($d in @("apps", "deploy")) {
    Copy-Item -Recurse (Join-Path $root $d) (Join-Path $stage $d)
}
Get-ChildItem $stage -Recurse -Force -Filter ".gdignore" | Remove-Item -Force
Copy-Item (Join-Path $root "tools\release\install.ps1") $stage
Copy-Item (Join-Path $root "tools\release\uninstall.ps1") $stage
Copy-Item (Join-Path $root "tools\setup.ps1") (Join-Path $stage "check-requirements.ps1")
Copy-Item (Join-Path $root "tools\dev-cluster.ps1") $stage
Copy-Item (Join-Path $root "tools\dev-users.ps1") $stage
Set-Content -Path (Join-Path $stage "VERSION") -Value $version -Encoding ascii
if ($Edition) { Set-Content -Path (Join-Path $stage "EDITION") -Value $label -Encoding ascii }

Compress-Archive -Path $stage -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText("$zip.sha256", "$hash  $name.zip`n")   # LF, so sha256sum -c works everywhere
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "`nBuilt $zip ($mb MB)" -ForegroundColor Cyan
Write-Host "SHA256 $hash"
Write-Host "Unpacked copy for testing: $stage"
