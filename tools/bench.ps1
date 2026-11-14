# Benchmarks the three graphics presets against the last release and writes a
# comparison table (docs\BENCHMARK.md) plus the raw numbers (dist\bench\*.json).
#
#   powershell -ExecutionPolicy Bypass -File tools\bench.ps1
#   powershell -ExecutionPolicy Bypass -File tools\bench.ps1 -Baseline v1.0.1 -Runs 2
#
# The baseline is a git ref: it is checked out into a temporary worktree, the
# benchmark script (scripts\bench.gd, which only uses things the game has always
# had) is dropped into it, and it flies the same camera route with vsync off.
# Each configuration runs -Runs times and the median run is reported.
param([string]$Baseline = "de600e8", [int]$Runs = 3, [string]$Resolution = "1920x1080", [string]$World = "kubernetes")
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $here "..")).Path
$godot = Join-Path $root "engine\Godot_v4.3-stable_win64_console.exe"
$out = Join-Path $root "dist\bench"
New-Item -ItemType Directory -Force $out | Out-Null
$settings = Join-Path $env:APPDATA "Godot\app_userdata\KubeFactory\settings.json"
$saved = if (Test-Path $settings) { Get-Content $settings -Raw } else { $null }

function Run-Bench($project, $label, $extra) {
    $results = @()
    for ($i = 1; $i -le $Runs; $i++) {
        $json = Join-Path $out "$label-$i.json"
        if (Test-Path $json) { Remove-Item $json }
        $argList = @("--path", $project, "--resolution", $Resolution, "--") + $extra + @("--bench=$json")
        $p = Start-Process -FilePath $godot -ArgumentList $argList -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $out "$label.log") -RedirectStandardError (Join-Path $out "$label.err")
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw "$label run $i did not finish" }
        if (-not (Test-Path $json)) { throw "$label run $i wrote no result (see $out\$label.err)" }
        $r = Get-Content $json -Raw | ConvertFrom-Json
        Write-Host ("  {0,-9} run {1}: {2,7:N1} fps  {3,6:N2} ms  {4,5} draws" -f $label, $i, $r.avg_fps, $r.avg_ms, $r.draw_calls)
        $results += $r
    }
    $median = ($results | Sort-Object avg_fps)[[int][math]::Floor($results.Count / 2)]
    $median.label = $label
    $median | ConvertTo-Json | Set-Content (Join-Path $out "$label.json") -Encoding ascii
    return $median
}

# the release, in a throwaway worktree with the benchmark script added
$wt = Join-Path $env:TEMP "kubefactory-bench-baseline"
if (Test-Path $wt) { git -C $root worktree remove --force $wt 2>$null | Out-Null }
git -C $root worktree add --detach $wt $Baseline | Out-Null
try {
    Copy-Item (Join-Path $root "scripts\bench.gd") (Join-Path $wt "scripts\bench.gd")
    $main = Join-Path $wt "scripts\main.gd"
    $t = [IO.File]::ReadAllText($main)
    $hook = "`t`telif a.begins_with(`"--bench=`"):`n`t`t`tshots = `"-`"`n`t`t`tload(`"res://scripts/bench.gd`").run(self, a.trim_prefix(`"--bench=`"), `"release`")`n`t`telif a == `"--flyby`":"
    $t2 = $t.Replace("`t`telif a == `"--flyby`":", $hook)
    if ($t2 -eq $t) { throw "could not add the benchmark hook to the baseline's main.gd" }
    [IO.File]::WriteAllText($main, $t2)
    Write-Host "Baseline $Baseline"
    $all = @(Run-Bench $wt "release" @("--demo=$World"))
} finally {
    git -C $root worktree remove --force $wt 2>$null | Out-Null
}

Write-Host "This checkout"
foreach ($id in "standard", "enhanced", "ultra") {
    $all += Run-Bench $root $id @("--demo=$World", "--gfx=$id")
}
if ($saved) { [IO.File]::WriteAllText($settings, $saved) }

$base = $all[0]
$md = @("# Graphics benchmark", "",
    "Baseline: release ``$Baseline``. $Resolution, vsync off, the ``$World`` demo world ($($base.machines) machines), a fixed 18-second camera route.",
    "GPU: $($base.gpu). Median of $Runs runs each. Reproduce with ``tools\bench.ps1``.", "",
    "| Build | Avg fps | vs release | Frame ms | 1% low fps | Draw calls | Objects | Primitives | Video mem MB |",
    "|---|---:|---:|---:|---:|---:|---:|---:|---:|")
foreach ($r in $all) {
    $rel = if ($r.label -eq "release") { "-" } else { "{0:+0;-0}%" -f (100.0 * ($r.avg_fps / $base.avg_fps - 1.0)) }
    $name = if ($r.label -eq "release") { "Release ($Baseline)" } else { (Get-Culture).TextInfo.ToTitleCase($r.label) }
    $md += "| $name | $($r.avg_fps) | $rel | $($r.avg_ms) | $($r.low_1pct_fps) | $($r.draw_calls) | $($r.objects) | $($r.primitives) | $($r.video_mem_mb) |"
}
$md += @("",
    "## Reading the table", "",
    "- **Standard draws the same picture as the release for less work.** Each machine's fixed parts are one mesh shared by every machine, so the renderer draws them as instances (see *Objects*).",
    "- **Enhanced and Ultra add to that picture**; their cost is the extra detail, lights, shadow resolution and, on Ultra, global illumination and reflections.",
    "- **Numbers move between sessions** (thermals, background load), the release's most of all. Compare rows within one run of this script, not across runs.",
    "- **Occlusion culling is built in but off by default** (``--occlusion`` turns it on). The yard is open, so on this route it hid almost nothing and its CPU cost made Standard about a third slower.",
    "- These are frame rates with vsync off on one machine; they rank the presets, they do not promise a frame rate on yours.")
$md | Set-Content (Join-Path $root "docs\BENCHMARK.md") -Encoding utf8
Write-Host ""
$md | Select-Object -Skip 5 | ForEach-Object { Write-Host $_ }
