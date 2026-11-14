# Turns a movie-writer .avi into an H.264 .mp4 (what Reddit, Discord and browsers
# want) with Windows' own encoder, so nothing has to be installed.
#
#   engine\Godot_v4.3-stable_win64.exe --path . --write-movie out.avi --fixed-fps 60 --resolution 1920x1080 -- --demo --trailer
#   powershell -ExecutionPolicy Bypass -File tools\to_mp4.ps1 out.avi docs\kubefactory.mp4
#
# A small silent copy for posting (Reddit, a phone): -Quality HD720p -Mbps 3.5 -Fps 30 -NoAudio
param([Parameter(Mandatory)][string]$In, [Parameter(Mandatory)][string]$Out, [double]$Mbps = 12, [int]$Fps = 60,
    [ValidateSet("HD1080p", "HD720p")][string]$Quality = "HD1080p", [switch]$NoAudio)
$ErrorActionPreference = "Stop"
$In = (Resolve-Path $In).Path
$Out = [IO.Path]::GetFullPath($Out)
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Media.Transcoding.MediaTranscoder, Windows.Media, ContentType = WindowsRuntime]
[void][Windows.Media.MediaProperties.MediaEncodingProfile, Windows.Media, ContentType = WindowsRuntime]

$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 }
function Await($op, [Type]$result) {
    $m = ($asTask | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0].MakeGenericMethod($result)
    $t = $m.Invoke($null, @($op)); $t.Wait(); $t.Result
}

$src = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($In)) ([Windows.Storage.StorageFile])
$dir = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync((Split-Path $Out))) ([Windows.Storage.StorageFolder])
$dst = Await ($dir.CreateFileAsync((Split-Path $Out -Leaf), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])

$mp4 = [Windows.Media.MediaProperties.MediaEncodingProfile]::CreateMp4([Windows.Media.MediaProperties.VideoEncodingQuality]::$Quality)
$mp4.Video.Bitrate = [uint32]($Mbps * 1000000)
if ($NoAudio) { $mp4.Audio = $null }      # no sound track at all, not a silent one
$mp4.Video.FrameRate.Numerator = $Fps
$mp4.Video.FrameRate.Denominator = 1

$coder = [Windows.Media.Transcoding.MediaTranscoder]::new()
$coder.HardwareAccelerationEnabled = $true
$prep = Await ($coder.PrepareFileTranscodeAsync($src, $dst, $mp4)) ([Windows.Media.Transcoding.PrepareTranscodeResult])
if (-not $prep.CanTranscode) { throw "Windows cannot transcode this file: $($prep.FailureReason)" }
$run = ($asTask | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncActionWithProgress`1' })[0].MakeGenericMethod([double]).Invoke($null, @($prep.TranscodeAsync()))
$run.Wait()
"{0}  ({1:N1} MB)" -f $Out, ((Get-Item $Out).Length / 1MB)
