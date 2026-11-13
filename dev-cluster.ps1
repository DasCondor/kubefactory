# Creates (or deletes) a disposable 3-node Kubernetes cluster that runs entirely
# in Docker containers, and fills it with sample workloads - including two that
# are broken on purpose, so there are problems to find in the game.
#
#   powershell -ExecutionPolicy Bypass -File dev-cluster.ps1          create
#   powershell -ExecutionPolicy Bypass -File dev-cluster.ps1 -Delete  remove
param([switch]$Delete)

$name = "kubefactory"
$ctx = "kind-$name"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Delete) {
    kind delete cluster --name $name
    exit $LASTEXITCODE
}

docker info --format "{{.ServerVersion}}" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Docker is not running - start Docker Desktop first." -ForegroundColor Red; exit 1 }

$existing = kind get clusters
if ($existing -notcontains $name) {
    kind create cluster --name $name --config (Join-Path $root "dev\kind-config.yaml")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
kubectl --context $ctx apply -f (Join-Path $root "dev\sample-workloads.yaml")
Write-Host "`nDev cluster ready. Play with:  .\play.bat --context=$ctx`n" -ForegroundColor Cyan
