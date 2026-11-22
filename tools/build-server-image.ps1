# Builds the KubeFactory server container image (deploy/server-image) on this
# machine: exports the game for Linux, builds kf-agent for Linux, and runs
# docker build. Nothing is pushed.
#
#   powershell -ExecutionPolicy Bypass -File tools\build-server-image.ps1 [-Tag kubefactory-server:dev]
#
# Needs the Godot 4.3 Linux export template
# (%APPDATA%\Godot\export_templates\4.3.stable\linux_release.x86_64), Go (or
# .toolchain\go, see tools\build-agent.ps1) and Docker.
param([string]$Tag = "kubefactory-server:dev")
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
$godot = Join-Path $root "engine\Godot_v4.3-stable_win64_console.exe"
$tpl = Join-Path $env:APPDATA "Godot\export_templates\4.3.stable\linux_release.x86_64"
if (-not (Test-Path $tpl)) { throw "the Linux export template is missing: $tpl" }
$ctx = Join-Path $root "dist\server-image"
if (Test-Path $ctx) { Remove-Item -Recurse -Force $ctx }
New-Item -ItemType Directory -Force $ctx | Out-Null
"" | Set-Content (Join-Path $ctx ".gdignore")

Write-Host "Exporting the game for Linux..."
$ErrorActionPreference = "Continue"   # Godot and docker write progress to stderr
& $godot --headless --path $root --export-release "Linux" (Join-Path $ctx "KubeFactory.x86_64") *> $null
if (-not (Test-Path (Join-Path $ctx "KubeFactory.x86_64"))) { throw "the Linux export failed" }

Write-Host "Building kf-agent for Linux..."
& powershell -ExecutionPolicy Bypass -File (Join-Path $root "tools\build-agent.ps1") -Os linux | Out-Null
if ($LASTEXITCODE -ne 0) { throw "the kf-agent build failed" }
Copy-Item (Join-Path $root "agent\bin\kf-agent") $ctx
Copy-Item (Join-Path $root "deploy\server-image\Dockerfile") $ctx

Write-Host "Building the image $Tag..."
docker build -t $Tag $ctx
if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
docker image inspect $Tag --format "Built {{index .RepoTags 0}}  {{.Id}}  {{.Size}} bytes"
