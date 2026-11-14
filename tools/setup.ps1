# KubeFactory setup: checks the software list and installs what is missing.
#
#   powershell -ExecutionPolicy Bypass -File setup.ps1            check + install required items
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -Cloud     also install the AWS / Azure / Google Cloud CLIs
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -CheckOnly report only, install nothing
param([switch]$Cloud, [switch]$CheckOnly)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# In the source tree this script lives in tools\; in a release zip it sits beside KubeFactory.exe.
$root = if (Test-Path (Join-Path $here "..\project.godot")) { (Resolve-Path (Join-Path $here "..")).Path } else { $here }
$godotVersion = "4.3-stable"
$godotExe = Join-Path $root "engine\Godot_v$godotVersion`_win64.exe"

function Have($cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Ensure($name, $cmd, $wingetId, $why, $required) {
    if (Have $cmd) {
        Write-Host ("  [ok]      {0,-22} {1}" -f $name, $why)
        return
    }
    $tag = "[missing]"
    if (-not $required) { $tag = "[optional]" }
    Write-Host ("  {0,-9} {1,-22} {2}" -f $tag, $name, $why) -ForegroundColor Yellow
    if ($CheckOnly -or -not $wingetId) { return }
    if ($required -or $Cloud) {
        Write-Host "            installing $wingetId with winget..."
        winget install --id $wingetId -e --accept-source-agreements --accept-package-agreements
    }
}

Write-Host "`nKubeFactory - software check`n" -ForegroundColor Cyan

Write-Host "Required to play:"
if (Test-Path (Join-Path $root "KubeFactory.exe")) {
    Write-Host ("  [ok]      {0,-22} {1}" -f "KubeFactory.exe", "standalone build, nothing else needed to play")
} elseif (Test-Path $godotExe) {
    Write-Host ("  [ok]      {0,-22} {1}" -f "Godot $godotVersion", "game engine (portable, lives in .\engine)")
} else {
    Write-Host ("  [missing] {0,-22} {1}" -f "Godot $godotVersion", "game engine (portable, lives in .\engine)") -ForegroundColor Yellow
    if (-not $CheckOnly) {
        $zip = Join-Path $env:TEMP "godot-$godotVersion.zip"
        $url = "https://github.com/godotengine/godot/releases/download/$godotVersion/Godot_v$godotVersion`_win64.exe.zip"
        Write-Host "            downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $zip
        # pinned checksum of the official Godot 4.3 download
        $want = "ad09b7e19949327700dfbe64e35880a2a08091c0751277f5cc21b915e5df9b4fe93fb43c50d6bdfb9d16b46168592491aa698e0d2dbe9f92132e163dd77b97e1"
        if ((Get-FileHash $zip -Algorithm SHA512).Hash.ToLower() -ne $want) {
            Remove-Item $zip
            throw "The Godot download does not match its expected checksum; not installing it."
        }
        New-Item -ItemType Directory -Force (Join-Path $root "engine") | Out-Null
        Expand-Archive -Path $zip -DestinationPath (Join-Path $root "engine") -Force
        Remove-Item $zip
        New-Item -ItemType File -Force (Join-Path $root "engine\.gdignore") | Out-Null
    }
}

Write-Host "`nRequired to manage real clusters (the built-in simulation needs none of these):"
Ensure "kubectl" "kubectl" "Kubernetes.kubectl" "talks to every Kubernetes cluster in your kubeconfig" $true

Write-Host "`nLocal containers / dev cluster:"
Ensure "Docker Desktop" "docker" "Docker.DockerDesktop" "local containers; also hosts the dev cluster" $true
Ensure "kind" "kind" "Kubernetes.kind" "throwaway Kubernetes cluster inside Docker (dev-cluster.ps1)" $true

Write-Host "`nCloud logins (only for the clouds you use; pass -Cloud to install):"
Ensure "AWS CLI" "aws" "Amazon.AWSCLI" "EKS:  aws eks update-kubeconfig --name <cluster>" $false
Ensure "Azure CLI" "az" "Microsoft.AzureCLI" "AKS:  az aks get-credentials -g <group> -n <cluster>" $false
Ensure "kubelogin" "kubelogin" "Microsoft.Azure.Kubelogin" "AKS clusters that use Entra ID sign-in" $false
Ensure "Google Cloud SDK" "gcloud" "Google.CloudSDK" "GKE:  gcloud container clusters get-credentials <cluster>" $false
if (-not (Have "gke-gcloud-auth-plugin")) {
    Write-Host "  [optional] gke-gcloud-auth-plugin  GKE sign-in plugin:  gcloud components install gke-gcloud-auth-plugin" -ForegroundColor Yellow
}
Write-Host "  [info]    Rancher                no extra software: download the cluster's kubeconfig from the Rancher UI"
Write-Host "                                   and merge it (or point KUBECONFIG at it)."

$launcher = ".\play.bat"
if (Test-Path (Join-Path $root "KubeFactory.exe")) { $launcher = ".\KubeFactory.exe --" }
Write-Host "`nDone. Start the game with:  $launcher      (or  $launcher --demo)`n" -ForegroundColor Cyan
