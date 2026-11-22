# KubeFactory Clean slate: sets up a Docker host or a Kubernetes cluster on this
# Windows machine, from nothing, ready for KubeFactory. See docs/CLEAN_SLATE.md.
#
# Read it, then run it from an administrator PowerShell. It does not elevate itself.
#
#   .\install-kubefactory.ps1 -Plan                            what it would do here; changes nothing, no admin needed
#   .\install-kubefactory.ps1                                  a Docker host: WSL 2 and Docker Desktop
#   .\install-kubefactory.ps1 -Target docker-desktop           ...and Docker Desktop's built-in Kubernetes
#   .\install-kubefactory.ps1 -Target kind                     ...and a kind cluster named kubefactory
#   .\install-kubefactory.ps1 -Target k3s -WslDistro Ubuntu    k3s inside a WSL distribution that runs systemd
#   add -HostService to also install the KubeFactory host service (docs/HOST_SERVICE.md)
#
# Each step runs only if it is missing. The plan is shown first and you are asked
# before anything changes. What it may change:
#   WSL 2               wsl --install --no-distribution (Windows may need a restart)
#   Docker Desktop      winget install Docker.DockerDesktop (you accept its terms in winget and in Docker Desktop)
#   docker-users        adds you to the group, so Docker works without admin (sign out and in once)
#   kubectl, kind       winget install Kubernetes.kubectl / Kubernetes.kind
#   a kind cluster      kind create cluster (kind adds its context to your kubeconfig)
#   k3s in WSL          install-kubefactory.sh --target k3s inside the distribution, then its kubeconfig is
#                       saved to %USERPROFILE%\.kube\kubefactory-k3s.yaml, readable by you only
#   the host service    install-host.ps1
#
# It never turns on Docker Desktop's Kubernetes for you: it shows where the switch
# is and waits. It never prints a credential and never removes anything.
[CmdletBinding()]
param(
    [ValidateSet("docker", "docker-desktop", "kind", "k3s")][string]$Target = "docker",
    [switch]$HostService,
    [string]$WslDistro = "",
    [ValidatePattern("^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$")][string]$ClusterName = "kubefactory",
    [string]$Version = "latest",
    [switch]$Plan,
    [switch]$Yes
)
$ErrorActionPreference = "Stop"
$repo = "DasCondor/kubefactory"
$base = if ($Version -eq "latest") { "https://github.com/$repo/releases/latest/download" } else { "https://github.com/$repo/releases/download/$Version" }

function Say($t, $c = "Gray") { Write-Host $t -ForegroundColor $c }
function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
# run a native command, keep its output, ignore its stderr; $LASTEXITCODE is kept
function Quiet([scriptblock]$b) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & $b 2>$null } finally { $ErrorActionPreference = $old }
}
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}
function Wait-Until($what, $seconds, [scriptblock]$cond) {
    $deadline = (Get-Date).AddSeconds($seconds)
    Write-Host "  waiting for $what " -NoNewline
    while ((Get-Date) -lt $deadline) {
        if (& $cond) { Say " ready" Green; return $true }
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 5
    }
    Say " not yet (gave up after $seconds s)" Yellow
    return $false
}
# a companion script: beside this one, else from the release, checked against its SHA256SUMS
function Get-Companion($name) {
    $here = Join-Path $PSScriptRoot $name
    if ($PSScriptRoot -and (Test-Path $here)) { return $here }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kf-setup-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest "$base/$name" -OutFile (Join-Path $tmp $name) -UseBasicParsing
    Invoke-WebRequest "$base/SHA256SUMS" -OutFile (Join-Path $tmp "SHA256SUMS") -UseBasicParsing
    $want = (Get-Content (Join-Path $tmp "SHA256SUMS") | Where-Object { $_ -match ("\s" + [regex]::Escape($name) + "$") }) -replace "\s.*$", ""
    $got = (Get-FileHash (Join-Path $tmp $name) -Algorithm SHA256).Hash.ToLower()
    if (-not $want -or $want -ne $got) { throw "checksum mismatch for $name; nothing was run" }
    return (Join-Path $tmp $name)
}

# ----- what is on this machine (read only)

$dockerDir = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin"
function Docker-Exe { if (Have docker) { "docker" } elseif (Test-Path "$dockerDir\docker.exe") { "$dockerDir\docker.exe" } else { "" } }
function Kubectl-Exe { if (Have kubectl) { "kubectl" } elseif (Test-Path "$dockerDir\kubectl.exe") { "$dockerDir\kubectl.exe" } else { "" } }
function Engine-Version { $d = Docker-Exe; if (-not $d) { return "" }; $v = Quiet { & $d version --format "{{.Server.Version}}" }; if ($LASTEXITCODE -eq 0) { "$v".Trim() } else { "" } }
function Wsl-Ready { if (-not (Have wsl)) { return $false }; Quiet { wsl --status } | Out-Null; $LASTEXITCODE -eq 0 }
# newer Docker Desktop releases make no docker-users group: then there is nothing to join
function In-DockerUsers {
    if (-not (Get-LocalGroup -Name "docker-users" -ErrorAction SilentlyContinue)) { return $true }
    if ((whoami /groups /fo csv | Select-String "docker-users") -ne $null) { return $true }
    try { [bool](Get-LocalGroupMember -Group "docker-users" -ErrorAction Stop | Where-Object { $_.Name -like "*\$env:USERNAME" }) } catch { $false }
}
function DD-Kube-Ready { $k = Kubectl-Exe; if (-not $k) { return $false }; $r = Quiet { & $k --context docker-desktop --request-timeout=5s get --raw /readyz }; $LASTEXITCODE -eq 0 -and "$r".Trim() -eq "ok" }
function Kind-Cluster { if (-not (Have kind)) { return $false }; $c = Quiet { kind get clusters }; @($c) -contains $ClusterName }
function In-Wsl($cmd) { Quiet { wsl -d $WslDistro -u root -- sh -c $cmd } }
function Wsl-Systemd { if (-not $WslDistro) { return $false }; "$(In-Wsl 'ps -p 1 -o comm=')".Trim() -eq "systemd" }
function Wsl-K3s { if (-not $WslDistro) { return $false }; In-Wsl "command -v k3s" | Out-Null; $LASTEXITCODE -eq 0 }
function Host-Service { [bool](Get-Service KubeFactoryHost -ErrorAction SilentlyContinue) }
$k3sConfig = Join-Path $env:USERPROFILE ".kube\kubefactory-k3s.yaml"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Plan -and -not $admin) {
    Say "Run this from an administrator PowerShell (right-click PowerShell > Run as administrator). It does not elevate itself." Red
    Say "To see what it would do first, without admin: .\install-kubefactory.ps1 -Plan -Target $Target" Gray
    exit 1
}
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 19041) { Say "Windows 10 2004 (build 19041) or later is needed for WSL 2; this is build $build." Red; exit 1 }
if ($Target -eq "k3s" -and -not $WslDistro) {
    $WslDistro = "$(Quiet { wsl -l -q } | Where-Object { $_ -and $_ -notmatch '^docker-desktop' } | Select-Object -First 1)".Replace("`0", "").Trim()
}
if ($Target -eq "k3s" -and $HostService) {
    Say "-HostService with k3s: install the host service inside the Linux distribution instead (install-host.sh --source k3s, which needs Docker there)." Red
    exit 2
}
$needDocker = $Target -ne "k3s"

# ----- the plan: every step says whether it is already done

$steps = New-Object System.Collections.ArrayList
function Step($name, [bool]$done, [scriptblock]$run, $note = "") { [void]$steps.Add([pscustomobject]@{ Name = $name; Done = $done; Run = $run; Note = $note }) }

Step "WSL 2" (Wsl-Ready) {
    wsl --install --no-distribution
    if ($LASTEXITCODE -ne 0) { throw "wsl --install failed (exit $LASTEXITCODE)" }
    Say "WSL 2 is installed. Restart Windows, then run this script again to carry on." Yellow
    exit 0
}
if ($needDocker) {
    Step "Docker Desktop" ([bool](Docker-Exe)) {
        if (-not (Have winget)) { throw "winget is not available. Install Docker Desktop from https://www.docker.com/products/docker-desktop/ and run this again." }
        # no --accept flags: winget and Docker Desktop show you their terms
        winget install -e --id Docker.DockerDesktop
        if ($LASTEXITCODE -ne 0) { throw "winget could not install Docker Desktop (exit $LASTEXITCODE)" }
        Refresh-Path
    } "winget install Docker.DockerDesktop"
    Step "you in the docker-users group" (In-DockerUsers) {
        Add-LocalGroupMember -Group "docker-users" -Member "$env:USERDOMAIN\$env:USERNAME"
        Say "  Added. Sign out of Windows and back in once so Docker works without admin." Yellow
    } "so Docker works without admin"
    Step "Docker engine answering" ([bool](Engine-Version)) {
        Say "  Start Docker Desktop from the Start menu as yourself (not as admin) and accept its terms. This script waits up to 10 minutes." Cyan
        if (-not (Wait-Until "the Docker engine" 600 { [bool](Engine-Version) })) { throw "Docker's engine did not answer. Start Docker Desktop, then run this again." }
    } "you start Docker Desktop; the script waits"
}
switch ($Target) {
    "docker-desktop" {
        Step "Docker Desktop's Kubernetes" (DD-Kube-Ready) {
            Say "  In Docker Desktop: Settings (gear) > Kubernetes > Enable Kubernetes > Apply & restart." Cyan
            Say "  KubeFactory does not change Docker Desktop's settings for you. This script waits up to 15 minutes." Cyan
            if (-not (Wait-Until "the docker-desktop cluster" 900 { DD-Kube-Ready })) { throw "The docker-desktop cluster is not ready yet. Run this again once Docker Desktop shows Kubernetes running." }
        } "you switch it on in Docker Desktop; the script waits"
    }
    "kind" {
        Step "kubectl" ([bool](Kubectl-Exe)) {
            winget install -e --id Kubernetes.kubectl
            if ($LASTEXITCODE -ne 0) { throw "winget could not install kubectl (exit $LASTEXITCODE)" }
            Refresh-Path
        } "winget install Kubernetes.kubectl"
        Step "kind" (Have kind) {
            winget install -e --id Kubernetes.kind
            if ($LASTEXITCODE -ne 0) { throw "winget could not install kind (exit $LASTEXITCODE)" }
            Refresh-Path
        } "winget install Kubernetes.kind"
        Step "kind cluster $ClusterName" (Kind-Cluster) {
            kind create cluster --name $ClusterName --wait 180s
            if ($LASTEXITCODE -ne 0) { throw "kind could not create the cluster (exit $LASTEXITCODE)" }
        } "context kind-$ClusterName in your kubeconfig"
    }
    "k3s" {
        $hasDistro = [bool]$WslDistro
        Step "a WSL distribution with systemd ($(if ($hasDistro) { $WslDistro } else { 'none found' }))" (Wsl-Systemd) {
            Say "  This step needs you:" Cyan
            if (-not $WslDistro) { Say "    wsl --install -d Ubuntu      (then create its user when it asks)" Cyan }
            Say "    In the distribution, put these two lines in /etc/wsl.conf:   [boot]   systemd=true" Cyan
            Say "    Then: wsl --shutdown, and run this script again with -WslDistro <name>." Cyan
            exit 0
        } "you turn on systemd in the distribution"
        Step "k3s in $WslDistro" (Wsl-K3s) {
            $sh = Get-Companion "install-kubefactory.sh"
            $full = (Resolve-Path $sh).Path
            $linux = "/mnt/" + $full.Substring(0, 1).ToLower() + $full.Substring(2).Replace("\", "/")
            wsl -d $WslDistro -u root -- sh $linux --target k3s --yes
            if ($LASTEXITCODE -ne 0) { throw "k3s did not install in $WslDistro (exit $LASTEXITCODE)" }
        } "install-kubefactory.sh --target k3s"
        Step "k3s kubeconfig for Windows" (Test-Path $k3sConfig) {
            New-Item -ItemType Directory -Force (Split-Path $k3sConfig) | Out-Null
            $text = (Quiet { wsl -d $WslDistro -u root -- cat /etc/rancher/k3s/k3s.yaml }) -join "`n"
            if (-not $text.Contains("server:")) { throw "could not read k3s's kubeconfig in $WslDistro" }
            # WSL 2 forwards localhost, so 127.0.0.1:6443 reaches k3s from Windows; the context gets a clear name
            $text = $text.Replace(": default", ": kubefactory-k3s")
            [IO.File]::WriteAllText($k3sConfig, $text + "`n", (New-Object Text.UTF8Encoding($false)))
            icacls $k3sConfig /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):F" "SYSTEM:F" | Out-Null
            Say "  Saved $k3sConfig (readable by you only). In KubeFactory: Switch cluster > Add or manage kubeconfigs." Green
        } "%USERPROFILE%\.kube\kubefactory-k3s.yaml"
    }
}
if ($HostService) {
    Step "KubeFactory host service" (Host-Service) {
        $installer = Get-Companion "install-host.ps1"
        $a = @{ Version = $Version }
        $tmpKube = ""
        try {
            switch ($Target) {
                "docker" { $a.Source = "docker" }
                "docker-desktop" {
                    $tmpKube = Join-Path ([IO.Path]::GetTempPath()) ("kf-kube-" + [guid]::NewGuid() + ".yaml")
                    $k = Kubectl-Exe
                    $cfgText = Quiet { & $k config view --minify --flatten --context docker-desktop }
                    [IO.File]::WriteAllText($tmpKube, ($cfgText -join "`n"), (New-Object Text.UTF8Encoding($false)))
                    $a.Source = "kube"; $a.Kubeconfig = $tmpKube
                }
                "kind" {
                    # the address other containers on the kind network use
                    $tmpKube = Join-Path ([IO.Path]::GetTempPath()) ("kf-kube-" + [guid]::NewGuid() + ".yaml")
                    $cfgText = Quiet { kind get kubeconfig --internal --name $ClusterName }
                    [IO.File]::WriteAllText($tmpKube, ($cfgText -join "`n"), (New-Object Text.UTF8Encoding($false)))
                    $a.Source = "kube"; $a.Kubeconfig = $tmpKube; $a.Network = "kind"
                }
            }
            & $installer @a
            if ($LASTEXITCODE -ne 0) { throw "install-host.ps1 failed (exit $LASTEXITCODE)" }
        } finally { if ($tmpKube -and (Test-Path $tmpKube)) { Remove-Item $tmpKube -Force } }
    } "install-host.ps1 -Source $(switch ($Target) { 'docker' { 'docker' } default { 'kube' } })"
}

Say ""
Say "KubeFactory Clean slate  -  target: $Target$(if ($HostService) { ' + host service' })" White
foreach ($s in $steps) {
    if ($s.Done) { Say ("  [done]  " + $s.Name) Green } else { Say ("  [todo]  " + $s.Name + $(if ($s.Note) { "   ($($s.Note))" } else { "" })) Yellow }
}
$todo = @($steps | Where-Object { -not $_.Done })
if ($todo.Count -eq 0) {
    Say "Everything is already in place." Green
} elseif ($Plan) {
    Say "Plan only: nothing was changed. Run it without -Plan, as administrator, to do the steps marked todo." Gray
    exit 0
} else {
    if (-not $Yes) {
        $answer = Read-Host "Do the $($todo.Count) step(s) marked todo? (y/N)"
        if ($answer -notmatch "^(y|yes)$") { Say "Nothing was changed." Gray; exit 0 }
    }
    foreach ($s in $todo) {
        Say ""
        Say ("==> " + $s.Name) White
        try { & $s.Run } catch { Say ("Stopped at: " + $s.Name + ". " + $_.Exception.Message) Red; Say "Steps before it are kept. Fix the cause and run this script again; it carries on from here." Gray; exit 1 }
    }
}
Say ""
Say "Next, in KubeFactory: Esc > Switch cluster > Discover local connections." Green
switch ($Target) {
    "docker" { Say "  Pick the Docker engine (context desktop-linux or default)." Gray }
    "docker-desktop" { Say "  Pick the docker-desktop context." Gray }
    "kind" { Say "  Pick the kind-$ClusterName context." Gray }
    "k3s" { Say "  Add $k3sConfig with Add or manage kubeconfigs, then pick kubefactory-k3s." Gray }
}
