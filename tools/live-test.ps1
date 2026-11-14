# Runs the companion against a real, disposable Kubernetes API server
# (kube-apiserver + etcd from the Kubernetes project's envtest, no Docker).
# Fetches those two binaries into .toolchain\ on first use. See tests\live\live_test.py
# for what it can and cannot prove.
#
#   powershell -ExecutionPolicy Bypass -File tools\live-test.ps1
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
$tc = Join-Path $root ".toolchain"
$go = (Get-Command go -ErrorAction SilentlyContinue).Source
if (-not $go) {
    $go = Join-Path $tc "go\bin\go.exe"
    if (-not (Test-Path $go)) { Write-Host "Go was not found. Run tools\build-agent.ps1 -Fetch first." -ForegroundColor Red; exit 1 }
    $env:GOROOT = Join-Path $tc "go"; $env:GOPATH = Join-Path $tc "gopath"; $env:GOTOOLCHAIN = "local"
}
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "tools\build-agent.ps1") | Select-Object -Last 1
$srv = Join-Path $tc "bin\kf-test-apiserver.exe"
Push-Location (Join-Path $root "tests\live\apiserver")
try {
    & $go build -o $srv .
    if ($LASTEXITCODE -ne 0) { throw "the test API server launcher did not build" }
    $assets = & $go run sigs.k8s.io/controller-runtime/tools/setup-envtest@release-0.20 use 1.32.x --bin-dir (Join-Path $tc "envtest") -p path
    if ($LASTEXITCODE -ne 0) { throw "could not fetch kube-apiserver and etcd" }
} finally { Pop-Location }
$env:KUBEBUILDER_ASSETS = ($assets | Select-Object -Last 1)
python (Join-Path $root "tests\live\live_test.py") $root (Join-Path $root "agent\bin\kf-agent.exe") $srv
exit $LASTEXITCODE