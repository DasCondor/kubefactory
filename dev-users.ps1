# Sets up the multi-user pieces on the local dev cluster and creates two extra
# test identities, so you can try multi-user play on one machine:
#
#   kf-alice   operator, limited to the "shop" namespace, tools up to Mk.3
#   kf-bob     viewer across the cluster, policy would allow Mk.3 but his
#              cluster permissions are read-only
#
#   powershell -ExecutionPolicy Bypass -File dev-users.ps1
#   .\play.bat --context=kind-kubefactory     (you, admin)
#   .\play.bat --context=kf-alice             (second window)
#   .\play.bat --context=kf-bob               (third window)
param([string]$Context = "kind-kubefactory")

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$k = @("--context", $Context)

kubectl @k apply -f (Join-Path $root "deploy\kubefactory.yaml")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$cluster = kubectl config view -o "jsonpath={.contexts[?(@.name=='$Context')].context.cluster}"

foreach ($name in @("alice", "bob")) {
    kubectl @k create serviceaccount $name -n kubefactory 2>$null | Out-Null
}
kubectl @k create rolebinding alice-ops -n shop --clusterrole=kubefactory-operator --serviceaccount=kubefactory:alice 2>$null | Out-Null
kubectl @k create clusterrolebinding bob-view --clusterrole=kubefactory-viewer --serviceaccount=kubefactory:bob 2>$null | Out-Null

foreach ($name in @("alice", "bob")) {
    $token = kubectl @k create token $name -n kubefactory --duration=24h
    kubectl config set-credentials "kf-$name" --token=$token | Out-Null
    if ($name -eq "alice") {
        kubectl config set-context "kf-$name" --cluster=$cluster --user="kf-$name" --namespace=shop | Out-Null
    } else {
        kubectl config set-context "kf-$name" --cluster=$cluster --user="kf-$name" | Out-Null
    }
}
Write-Host "`nContexts kf-alice and kf-bob are ready (tokens last 24 hours).`n" -ForegroundColor Cyan
