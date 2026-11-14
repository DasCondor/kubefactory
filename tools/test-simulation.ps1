# Exercise simulation startup and the cluster switcher without a Docker engine.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$dir = Join-Path $root "dist\simulation-test"
New-Item -ItemType Directory -Force $dir | Out-Null
$go = (Get-Command go -ErrorAction SilentlyContinue).Source
if (-not $go) { $go = Join-Path $root ".toolchain\go\bin\go.exe" }
if (-not (Test-Path $go)) { throw "Go is required; run tools\build-agent.ps1 -Fetch first." }
$oldPath = $env:PATH
$oldMarker = $env:KF_TEST_DOCKER_MARKER
$oldToolchain = $env:GOTOOLCHAIN
try {
    $env:GOTOOLCHAIN = "local"
    & $go build -o (Join-Path $dir "docker.exe") (Join-Path $root "tests\live\docker_probe_stub.go")
    if ($LASTEXITCODE -ne 0) { throw "Could not build the Docker test stub." }
    $env:KF_TEST_DOCKER_MARKER = Join-Path $dir "called.txt"
    if (Test-Path -LiteralPath $env:KF_TEST_DOCKER_MARKER) { Remove-Item -LiteralPath $env:KF_TEST_DOCKER_MARKER }
    $env:PATH = "$dir;$oldPath"
    $godot = Join-Path $root "engine\Godot_v4.3-stable_win64_console.exe"
    & $godot --headless --path $root -s tests/live/simulation_isolation_test.gd
    if ($LASTEXITCODE -ne 0) { throw "Simulation isolation test failed." }
    foreach ($renderer in @("gl_compatibility", "forward_plus")) {
        & $godot --rendering-method $renderer --path $root -s tests/live/simulation_ui_test.gd -- --demo
        if ($LASTEXITCODE -ne 0) { throw "Simulation switcher test failed ($renderer)." }
    }
} finally {
    $env:PATH = $oldPath
    $env:KF_TEST_DOCKER_MARKER = $oldMarker
    $env:GOTOOLCHAIN = $oldToolchain
}
