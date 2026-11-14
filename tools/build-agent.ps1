# Builds the native companion (agent\bin\kf-agent.exe) that gives KubeFactory
# kubeconfig connectivity without kubectl, port-forwarding, read-only file
# inspection and LiveView.
#
#   powershell -ExecutionPolicy Bypass -File tools\build-agent.ps1          build
#   powershell -ExecutionPolicy Bypass -File tools\build-agent.ps1 -Test    run its tests, then build
#
# Needs Go. If `go` is not on PATH it uses (and, with -Fetch, downloads and
# checksum-verifies) a private copy under .toolchain\, which git ignores; nothing
# is installed system-wide.
param([switch]$Test, [switch]$Fetch, [string]$Os = "windows", [string]$Arch = "amd64")
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")).Path
$tc = Join-Path $root ".toolchain"
$go = (Get-Command go -ErrorAction SilentlyContinue).Source
if (-not $go) {
    $go = Join-Path $tc "go\bin\go.exe"
    if (-not (Test-Path $go)) {
        if (-not $Fetch) { Write-Host "Go was not found. Install it, or rerun with -Fetch to download a private copy into .toolchain\." -ForegroundColor Red; exit 1 }
        $ver = "go1.26.11"; $sha = "71ae086f0137e665f855a811cc119152b6a783e0bbc1b906e709f46d80141eb0"
        New-Item -ItemType Directory -Force $tc | Out-Null
        $zip = Join-Path $tc "go.zip"
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri "https://go.dev/dl/$ver.windows-amd64.zip" -OutFile $zip -UseBasicParsing
        if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -ne $sha) { Remove-Item $zip; throw "checksum mismatch for the Go download" }
        Expand-Archive -Path $zip -DestinationPath $tc -Force
        Remove-Item $zip
    }
    $env:GOROOT = Join-Path $tc "go"
    $env:GOPATH = Join-Path $tc "gopath"
}
$env:GOTOOLCHAIN = "local"
$env:GOOS = $Os; $env:GOARCH = $Arch; $env:CGO_ENABLED = "0"
Push-Location (Join-Path $root "agent")
try {
    if ($Test) {
        $env:GOOS = ""; $env:GOARCH = ""
        & $go vet ./...; if ($LASTEXITCODE -ne 0) { throw "go vet failed" }
        & $go test ./... ; if ($LASTEXITCODE -ne 0) { throw "agent tests failed" }
        $env:GOOS = $Os; $env:GOARCH = $Arch
    }
    New-Item -ItemType Directory -Force bin | Out-Null
    $name = if ($Os -eq "windows") { "kf-agent.exe" } else { "kf-agent" }
    & $go build -trimpath -ldflags "-s -w" -o (Join-Path "bin" $name) .
    if ($LASTEXITCODE -ne 0) { throw "agent build failed" }
    $f = Get-Item (Join-Path "bin" $name)
    Write-Host ("Built {0} ({1:N1} MB)  sha256 {2}" -f $f.FullName, ($f.Length / 1MB), (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower())
} finally { Pop-Location }
