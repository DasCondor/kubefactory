# Records a scripted tour and writes its MP4 and GIF for the README and wiki.
# Re-run it for every major change a tour shows, so the media matches the game.
#
#   powershell -ExecutionPolicy Bypass -File tools\record-tour.ps1 board
#
# Tours (each is a dev mode in scripts/main.gd):
#   board     the connection whiteboard: isometric, callouts, 2D  -> docs/wiki/media/board-tour.mp4 / .gif
#   trailer   the factory tour                                     -> docs/wiki/media/trailer.mp4 / .gif
#
# The game's settings.json is backed up first and restored afterwards (a tour
# may switch views). The MP4 uses Windows' own encoder (tools\to_mp4.ps1); the
# GIF comes from a second, smaller recording (tools\make_gif.py, needs Pillow).
param([Parameter(Mandatory)][ValidateSet("board", "trailer")][string]$Tour)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot
$godot = Join-Path $root "engine\Godot_v4.3-stable_win64_console.exe"
$tours = @{
    board   = @{ Args = @("--demo=docker-media-gatherer", "--board-tour"); Name = "board-tour" }
    trailer = @{ Args = @("--demo", "--trailer"); Name = "trailer" }
}
$t = $tours[$Tour]
$media = Join-Path $root "docs\wiki\media"
$work = Join-Path ([IO.Path]::GetTempPath()) ("kf-tour-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force "$work\frames" | Out-Null
$settings = Join-Path $env:APPDATA "Godot\app_userdata\KubeFactory\settings.json"
$backup = "$work\settings.json"
if (Test-Path $settings) { Copy-Item $settings $backup }
try {
    $ErrorActionPreference = "Continue"     # Godot writes progress to stderr
    Write-Host "Recording the video..."
    & $godot --path $root --write-movie "$work\tour.avi" --fixed-fps 30 --resolution 1280x720 -- @($t.Args) *> "$work\video.log"
    Write-Host "Recording the GIF frames..."
    & $godot --path $root --write-movie "$work\frames\f.png" --fixed-fps 8 --resolution 800x450 -- @($t.Args) *> "$work\frames.log"
    $ErrorActionPreference = "Stop"
    if (-not (Test-Path "$work\tour.avi")) { throw "the video was not recorded; see $work\video.log" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "to_mp4.ps1") "$work\tour.avi" (Join-Path $media "$($t.Name).mp4") -Quality HD720p -Mbps 2.5 -Fps 30 -NoAudio
    & python (Join-Path $PSScriptRoot "make_gif.py") "$work\frames" (Join-Path $media "$($t.Name).gif") 125
} finally {
    if (Test-Path $backup) { Copy-Item $backup $settings -Force }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Get-Item (Join-Path $media "$($t.Name).*") | ForEach-Object { "{0}  {1:N1} MB" -f $_.Name, ($_.Length / 1MB) }
