# Installs the KubeFactory host service (kf-host) on this Windows machine:
# the high-availability deployment, see docs/HOST_SERVICE.md.
#
# Run it from an administrator PowerShell. It does not elevate itself.
#
#   .\install-host.ps1                                  demo server, access point on 127.0.0.1:7666
#   .\install-host.ps1 -Source docker                   this machine's Docker engine
#   .\install-host.ps1 -Source kube -Kubeconfig C:\kf\viewer.yaml [-Context prod]
#   .\install-host.ps1 -Listen 0.0.0.0:7666 -TlsCert C:\kf\cert.pem -TlsKey C:\kf\key.pem
#   .\install-host.ps1 -Binary .\kf-host.exe -Image kubefactory-server:dev -NoPull   a local build
#   .\install-host.ps1 -Uninstall [-RemoveContainer]
#
# What it changes, and nothing else:
#   C:\Program Files\KubeFactory\Host\kf-host.exe      the service program
#   C:\ProgramData\KubeFactory\Host\host.json          its settings (kept if present, unless -Force)
#   the Windows service KubeFactoryHost                 automatic (delayed) start
#   Docker: the container, volume and image named in host.json, created by the service
#
# It never prints or stores a token. The server writes its first tokens into its
# data volume; the script tells you how to read them once and delete them.
[CmdletBinding()]
param(
    [ValidateSet("demo", "docker", "kube")][string]$Source = "demo",
    [string]$Kubeconfig = "",
    [string]$Context = "",
    [string]$Listen = "127.0.0.1:7666",
    [string]$TlsCert = "",
    [string]$TlsKey = "",
    [string]$Image = "",
    [switch]$NoPull,
    [switch]$ReadOnly,
    [string]$Binary = "",
    [string]$Version = "latest",
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$RemoveContainer
)
$ErrorActionPreference = "Stop"
$repo = "DasCondor/kubefactory"
$progDir = Join-Path $env:ProgramFiles "KubeFactory\Host"
$exe = Join-Path $progDir "kf-host.exe"
$dataDir = Join-Path $env:ProgramData "KubeFactory\Host"
$config = Join-Path $dataDir "host.json"

function Say($t, $c = "Gray") { Write-Host $t -ForegroundColor $c }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Say "Run this from an administrator PowerShell (right-click PowerShell > Run as administrator). It does not elevate itself." Red
    exit 1
}

if ($Uninstall) {
    if (-not (Test-Path $exe)) { Say "kf-host is not installed here." Yellow; exit 0 }
    $a = @("uninstall", "--config", $config)
    if ($RemoveContainer) { $a += "--remove-container" }
    & $exe @a
    Remove-Item $exe -Force
    Say "Removed the program. Settings and logs stay in $dataDir; delete that folder to remove them." Green
    exit 0
}

# Docker must be installed and answering: the service manages a container.
$docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
if (-not $docker) { Say "Docker was not found. Install Docker Desktop first (or use KubeFactory's Clean slate setup)." Red; exit 1 }
$ErrorActionPreference = "Continue"
$engine = (& docker version --format "{{.Server.Version}}" 2>$null)
$ErrorActionPreference = "Stop"
if (-not $engine) { Say "Docker is installed but its engine is not answering. Start Docker Desktop and run this again." Red; exit 1 }
Say "Docker engine $engine"

# The program: a local file, or the release asset checked against the release's SHA256SUMS.
New-Item -ItemType Directory -Force $progDir, $dataDir | Out-Null
if ($Binary) {
    Copy-Item (Resolve-Path $Binary) $exe -Force
} else {
    $base = if ($Version -eq "latest") { "https://github.com/$repo/releases/latest/download" } else { "https://github.com/$repo/releases/download/$Version" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kf-host-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest "$base/kf-host-windows-amd64.exe" -OutFile "$tmp\kf-host.exe" -UseBasicParsing
        Invoke-WebRequest "$base/SHA256SUMS" -OutFile "$tmp\SHA256SUMS" -UseBasicParsing
        $want = (Get-Content "$tmp\SHA256SUMS" | Where-Object { $_ -match "\skf-host-windows-amd64\.exe$" }) -replace "\s.*$", ""
        $got = (Get-FileHash "$tmp\kf-host.exe" -Algorithm SHA256).Hash.ToLower()
        if (-not $want -or $want -ne $got) { throw "checksum mismatch for kf-host-windows-amd64.exe; nothing was installed" }
        Copy-Item "$tmp\kf-host.exe" $exe -Force
    } finally { Remove-Item -Recurse -Force $tmp }
}
Say "Installed $exe ($(& $exe version))"

# Settings: written once; an existing host.json is the admin's and is kept.
if ((Test-Path $config) -and -not $Force) {
    Say "Keeping the existing settings in $config (use -Force to replace them)." Yellow
} else {
    if (-not $Image) { $Image = if ($Version -eq "latest") { "ghcr.io/dascondor/kubefactory-server:latest" } else { "ghcr.io/dascondor/kubefactory-server:$($Version.TrimStart('v'))" } }
    $cfg = [ordered]@{
        container = "kubefactory-server"; image = $Image; pull = -not $NoPull; source = @("--demo")
        read_only = [bool]$ReadOnly; volume = "kubefactory-server-data"; mounts = @(); env = @()
        internal_port = 17666; listen = $Listen; tls_cert = $TlsCert; tls_key = $TlsKey; interval_seconds = 30
    }
    switch ($Source) {
        "docker" {
            Say "A Docker source gives the server container this machine's Docker socket: it can do anything Docker can. Players still act only through their token's role." Yellow
            $cfg.source = @("--docker")
            $cfg.mounts = @(@{ host = "/var/run/docker.sock"; container = "/var/run/docker.sock"; read_only = $false })
            $cfg.user = "0"   # Docker Desktop's socket is root-only inside containers
        }
        "kube" {
            if (-not $Kubeconfig -or -not (Test-Path $Kubeconfig)) { Say "-Source kube needs -Kubeconfig <file>: a kubeconfig for the account the server should use (a dedicated, limited one is best)." Red; exit 1 }
            $kdir = Join-Path $dataDir "kube"
            New-Item -ItemType Directory -Force $kdir | Out-Null
            Copy-Item (Resolve-Path $Kubeconfig) (Join-Path $kdir "config") -Force
            # only SYSTEM and Administrators may read the copy
            icacls $kdir /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null
            $cfg.mounts = @(@{ host = $kdir; container = "/kube"; read_only = $true })
            $cfg.source = @("--kubeconfig=/kube/config")
            if ($Context) { $cfg.source += "--context=$Context" }
            Say "Copied the kubeconfig to $kdir (Administrators only). Inside the container 127.0.0.1 is the container itself: use a kubeconfig whose server address the container can reach (Docker Desktop's Kubernetes: kubernetes.docker.internal). Exec auth helpers are not available inside the container." Yellow
        }
    }
    [IO.File]::WriteAllText($config, ($cfg | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    Say "Wrote $config"
}

if (-not $Listen.StartsWith("127.0.0.1") -and -not $TlsCert) { Say "The access point listens on $Listen without TLS: tokens would cross the network unencrypted. Prefer -TlsCert/-TlsKey, an SSH tunnel or a TLS reverse proxy." Yellow }
& $exe install --config $config
if ($LASTEXITCODE -ne 0) { Say "The service could not be installed (see above)." Red; exit 1 }
Say ""
Say "KubeFactory host service is running. It checks every 30 seconds that the server container is up." Green
Say "  status:      & '$exe' status"
Say "  log:         $dataDir\host.log"
Say "  connect:     in the game, Esc > Switch cluster > KubeFactory server..., address ws://$Listen"
Say ""
Say "The server's first tokens are written once, inside its data volume. When the container is up (a minute on the first start), read them, hand each to one person, then delete the file:"
Say "  docker exec kubefactory-server cat /data/server-new-tokens.txt"
Say "  docker exec kubefactory-server rm /data/server-new-tokens.txt"
