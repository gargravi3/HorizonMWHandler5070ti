<#
.SYNOPSIS
    Samples video memory, commit charge and per-instance private bytes to a CSV
    while a session runs.

.DESCRIPTION
    Exists because the numbers that decide how many instances fit are only
    observable while the instances are alive, and by the time a crash is reported
    everything has exited and the GPU is back to its idle baseline. Video memory at
    the Low preset has now been promised three times and missed three times for
    exactly that reason.

    Per-process video memory is not available on GeForce cards: nvidia-smi reports
    [N/A] for used_memory per compute app. Per-instance figures here are therefore
    derived as (total used - baseline) / instance count, and the baseline is captured
    before any instance starts. That is an approximation and is labelled as one in
    the CSV rather than presented as a measurement.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Sample-Resources.ps1 -DurationMinutes 45
#>
[CmdletBinding()]
param(
    [int]$DurationMinutes = 60,
    [int]$IntervalSeconds = 5,
    [string]$CsvPath = (Join-Path $env:TEMP 'HMWResources.csv'),
    [string]$ProcessName = 'hmw-mod'
)

$ErrorActionPreference = 'Continue'

function Get-VramUsedMiB {
    $out = & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    return [int]($out | Select-Object -First 1).ToString().Trim()
}

$vramTotal = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
$vramTotal = if ($vramTotal) { [int]($vramTotal | Select-Object -First 1).ToString().Trim() } else { 0 }

# Baseline must be taken with nothing running, otherwise every derived per-instance
# figure inherits the error. If instances are already up, say so instead of guessing.
$startCount = @(Get-Process $ProcessName -ErrorAction SilentlyContinue).Count
$baseline = Get-VramUsedMiB
if ($startCount -gt 0) {
    "warning: $startCount instance(s) already running, so the VRAM baseline is not clean"
    "         per-instance figures in this run will understate usage"
}

"baseline VRAM $baseline MiB of $vramTotal MiB, $(if ($startCount -eq 0) { 'clean' } else { "with $startCount instance(s) up" })"
"sampling every ${IntervalSeconds}s for ${DurationMinutes}min -> $CsvPath"

'time,instances,vram_used_mib,vram_total_mib,vram_per_instance_mib_derived,commit_used_gb,commit_limit_gb,private_bytes_gb_total,peak_instances' |
    Set-Content -LiteralPath $CsvPath -Encoding Ascii

$deadline = (Get-Date).AddMinutes($DurationMinutes)
$peak = $startCount
$peakVram = $baseline

while ((Get-Date) -lt $deadline) {
    $procs = @(Get-Process $ProcessName -ErrorAction SilentlyContinue)
    $n = $procs.Count
    if ($n -gt $peak) { $peak = $n }

    $vram = Get-VramUsedMiB
    if ($vram -ne $null -and $vram -gt $peakVram) { $peakVram = $vram }

    $os = Get-CimInstance Win32_OperatingSystem
    $commitUsed  = ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) * 1KB / 1GB
    $commitLimit = $os.TotalVirtualMemorySize * 1KB / 1GB

    $priv = 0
    foreach ($p in $procs) { $priv += $p.PrivateMemorySize64 }

    $perInst = if ($n -gt 0 -and $vram -ne $null) { [math]::Round((($vram - $baseline) / $n), 0) } else { '' }

    '{0},{1},{2},{3},{4},{5:N1},{6:N1},{7:N1},{8}' -f `
        (Get-Date -Format 'HH:mm:ss'), $n, $vram, $vramTotal, $perInst, $commitUsed, $commitLimit, ($priv/1GB), $peak |
        Add-Content -LiteralPath $CsvPath -Encoding Ascii

    Start-Sleep -Seconds $IntervalSeconds
}

""
"done. peak instances $peak, peak VRAM $peakVram MiB of $vramTotal MiB"
if ($peak -gt 0) {
    "derived per-instance at peak: {0:N0} MiB" -f (($peakVram - $baseline) / $peak)
}
"csv: $CsvPath"
