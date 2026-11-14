# Runs the companion against a real, disposable Kubernetes API server
# (kube-apiserver + etcd from the Kubernetes project's envtest, no Docker).
# Fetches those two binaries into .toolchain\ on first use. See tests\live\live_test.py
# for what it can and cannot prove.
#
#   powershell -ExecutionPolicy Bypass -File tools\live-test.ps1
#   powershell -ExecutionPolicy Bypass -File tools\live-test.ps1 -Grafana
#
# -Grafana instead runs the Grafana provider against a real Grafana OSS (11.2.0, or -GrafanaVersion <x.y.z>): it is
# downloaded (checksum-verified) into .toolchain\, started on 127.0.0.1 with a throw-away
# data folder and a random admin password, and removed again. See tests\live\grafana_test.py.
param([switch]$Grafana, [string]$GrafanaVersion = "11.2.0", [switch]$Tautulli, [string]$TautulliVersion = "2.19.1", [switch]$Kind)
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
if ($Grafana) {
    $gh = Join-Path $tc ($(if ($GrafanaVersion -eq "11.2.0") { "grafana" } else { "grafana-$GrafanaVersion" }))
    if (-not (Test-Path (Join-Path $gh "bin\grafana.exe")) -and -not (Test-Path (Join-Path $gh "bin\grafana"))) {
        $z = Join-Path $tc "grafana.zip"; $u = "https://dl.grafana.com/oss/release/grafana-$GrafanaVersion.windows-amd64.zip"
        curl.exe -fsSL -o $z $u
        $want = (curl.exe -fsSL "$u.sha256").Trim().Split(" ")[0]
        if ((Get-FileHash $z -Algorithm SHA256).Hash.ToLower() -ne $want) { throw "checksum mismatch for the Grafana download" }
        Expand-Archive $z (Join-Path $tc "grafana_x") -Force
        Move-Item (Get-ChildItem (Join-Path $tc "grafana_x") -Directory | Select-Object -First 1).FullName $gh
        Remove-Item (Join-Path $tc "grafana_x") -Recurse -Force; Remove-Item $z
    }
    python (Join-Path $root "tests\live\grafana_test.py") $root (Join-Path $root "agent\bin\kf-agent.exe") $gh
    exit $LASTEXITCODE
}
if ($Kind) {
    # a real cluster with running containers: the disposable kind cluster from tools\dev-cluster.ps1
    if ((kind get clusters) -notcontains "kubefactory") { Write-Host "No kind cluster yet: run tools\dev-cluster.ps1 first (it needs Docker)." -ForegroundColor Red; exit 1 }
    python (Join-Path $root "tests\live\kind_test.py") $root (Join-Path $root "agent\bin\kf-agent.exe")
    exit $LASTEXITCODE
}
if ($Tautulli) {
    # Tautulli's released source for that tag, run with the Python on this computer, on 127.0.0.1
    # with a throw-away data folder and a random key. No Plex behind it: see tests\live\tautulli_test.py.
    $th = Join-Path $tc "tautulli-$TautulliVersion"
    if (-not (Test-Path (Join-Path $th "Tautulli.py"))) {
        $z = Join-Path $tc "tautulli.zip"
        curl.exe -fsSL -o $z "https://github.com/Tautulli/Tautulli/archive/refs/tags/v$TautulliVersion.zip"
        Expand-Archive $z (Join-Path $tc "tautulli_x") -Force
        Move-Item (Get-ChildItem (Join-Path $tc "tautulli_x") -Directory | Select-Object -First 1).FullName $th
        Remove-Item (Join-Path $tc "tautulli_x") -Recurse -Force; Remove-Item $z
    }
    python (Join-Path $root "tests\live\tautulli_test.py") $root (Join-Path $root "agent\bin\kf-agent.exe") $th
    exit $LASTEXITCODE
}
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