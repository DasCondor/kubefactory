# Builds the deployable release:
#
#   dist\KubeFactory-<version>-win64.zip          what you hand out / publish
#   dist\KubeFactory-<version>-win64.zip.sha256   its checksum
#
# The zip holds a standalone KubeFactory.exe (no engine or source needed), the
# editable config files, the bundled app setups, the cluster setup manifest, an
# installer and an uninstaller.
#
#   powershell -ExecutionPolicy Bypass -File package.ps1
#
# Needs the Godot export templates for the engine version in .\engine
# (%APPDATA%\Godot\export_templates\4.3.stable).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$godot = Join-Path $root "engine\Godot_v4.3-stable_win64_console.exe"
$version = (Select-String -Path (Join-Path $root "scripts\main.gd") -Pattern 'const VERSION = "(.+)"').Matches[0].Groups[1].Value
$name = "KubeFactory-$version-win64"
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
& $godot --headless --path $root --export-release "Windows Desktop" (Join-Path $stage "KubeFactory.exe") 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
if (-not (Test-Path (Join-Path $stage "KubeFactory.exe"))) { Write-Host "Export failed." -ForegroundColor Red; exit 1 }

foreach ($f in @("README.md", "ADMIN.md", "LICENSE", "THIRDPARTY.md", "SECURITY.md", "catalogs.json", "portainer.json", "log-providers.json", "policy.json")) {
    Copy-Item (Join-Path $root $f) $stage
}
foreach ($d in @("apps", "deploy", "dev")) {
    Copy-Item -Recurse (Join-Path $root $d) (Join-Path $stage $d)
}
Get-ChildItem $stage -Recurse -Force -Filter ".gdignore" | Remove-Item -Force
Copy-Item (Join-Path $root "release\install.ps1") $stage
Copy-Item (Join-Path $root "release\uninstall.ps1") $stage
Copy-Item (Join-Path $root "setup.ps1") (Join-Path $stage "check-requirements.ps1")
Copy-Item (Join-Path $root "dev-cluster.ps1") $stage
Copy-Item (Join-Path $root "dev-users.ps1") $stage
Set-Content -Path (Join-Path $stage "VERSION") -Value $version -Encoding ascii

Compress-Archive -Path $stage -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText("$zip.sha256", "$hash  $name.zip`n")   # LF, so sha256sum -c works everywhere
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "`nBuilt $zip ($mb MB)" -ForegroundColor Cyan
Write-Host "SHA256 $hash"
Write-Host "Unpacked copy for testing: $stage"
