<#
.SYNOPSIS
    Samples per-instance video memory, commit charge and private bytes to a CSV
    while a session runs.

.DESCRIPTION
    Exists because the numbers that decide how many instances fit are only
    observable while the instances are alive, and by the time a crash is reported
    everything has exited and the GPU is back to its idle baseline.

    PER-INSTANCE VIDEO MEMORY IS DIRECTLY MEASURABLE, from the Windows counter
    \GPU Process Memory(pid_*)\Dedicated Usage. This script used to divide
    (total - baseline) by the instance count instead, on the belief that per-process
    video memory was unavailable on GeForce. That belief came from nvidia-smi, which
    does report [N/A] for used_memory per compute app, but the Windows counter works
    fine and needs no baseline, no clean start and no arithmetic.

    Use Dedicated Usage. NOT Local Usage: for four instances holding 3,791 MiB each,
    Local Usage reported 459 MiB each, and a single earlier sample of it reported one
    instance at 4,685 MiB with its three siblings near 800 MiB. Dedicated Usage
    matched the adapter total and nvidia-smi to within 1% on the same four processes.

    The derived column is kept alongside the measured one, because every earlier
    finding in this repo is expressed in derived numbers and dropping it would make
    them incomparable.

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

# Returns MiB of dedicated video memory per process id, or an empty hashtable if the
# counter set is unavailable. Instance names look like pid_1234_luid_0x..._phys_0 and
# a process can own more than one, so they are summed per pid.
function Get-VramByPid {
    $byPid = @{}
    try {
        $samples = (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
    } catch {
        return $byPid
    }
    foreach ($s in $samples) {
        if ($s.CookedValue -gt 0 -and $s.InstanceName -match '^pid_(\d+)') {
            $id = [int]$Matches[1]
            if (-not $byPid.ContainsKey($id)) { $byPid[$id] = 0 }
            $byPid[$id] += $s.CookedValue
        }
    }
    return $byPid
}

$vramTotal = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
$vramTotal = if ($vramTotal) { [int]($vramTotal | Select-Object -First 1).ToString().Trim() } else { 0 }

$startCount = @(Get-Process $ProcessName -ErrorAction SilentlyContinue).Count
$baseline = Get-VramUsedMiB
if ($startCount -gt 0) {
    "note: $startCount instance(s) already running, so the derived column understates usage"
    "      the measured column is unaffected: it needs no baseline"
}
if ((Get-VramByPid).Count -eq 0) {
    "warning: \GPU Process Memory counter unavailable, measured column will be empty"
}

"baseline VRAM $baseline MiB of $vramTotal MiB"
"sampling every ${IntervalSeconds}s for ${DurationMinutes}min -> $CsvPath"

'time,instances,vram_used_mib,vram_total_mib,vram_per_instance_mib_measured,vram_instances_total_mib_measured,vram_per_instance_mib_derived,commit_used_gb,commit_limit_gb,physical_used_gb,physical_total_gb,private_bytes_gb_total,peak_instances' |
    Set-Content -LiteralPath $CsvPath -Encoding Ascii

$deadline = (Get-Date).AddMinutes($DurationMinutes)
$peak = $startCount
$peakVram = $baseline
$peakMeasured = 0

while ((Get-Date) -lt $deadline) {
    $procs = @(Get-Process $ProcessName -ErrorAction SilentlyContinue)
    $n = $procs.Count
    if ($n -gt $peak) { $peak = $n }

    $vram = Get-VramUsedMiB
    if ($null -ne $vram -and $vram -gt $peakVram) { $peakVram = $vram }

    $byPid = Get-VramByPid
    $mine = 0
    foreach ($p in $procs) { if ($byPid.ContainsKey($p.Id)) { $mine += $byPid[$p.Id] } }
    $mineMiB = [math]::Round($mine / 1MB, 0)
    $perInstMeasured = if ($n -gt 0 -and $mineMiB -gt 0) { [math]::Round($mineMiB / $n, 0) } else { '' }
    if ($perInstMeasured -ne '' -and $perInstMeasured -gt $peakMeasured) { $peakMeasured = $perInstMeasured }

    $os = Get-CimInstance Win32_OperatingSystem
    $commitUsed  = ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) * 1KB / 1GB
    $commitLimit = $os.TotalVirtualMemorySize * 1KB / 1GB
    $physTotal   = $os.TotalVisibleMemorySize * 1KB / 1GB
    $physUsed    = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 1KB / 1GB

    $priv = 0
    foreach ($p in $procs) { $priv += $p.PrivateMemorySize64 }

    $perInstDerived = if ($n -gt 0 -and $null -ne $vram) { [math]::Round((($vram - $baseline) / $n), 0) } else { '' }

    '{0},{1},{2},{3},{4},{5},{6},{7:N1},{8:N1},{9:N1},{10:N1},{11:N1},{12}' -f `
        (Get-Date -Format 'HH:mm:ss'), $n, $vram, $vramTotal, $perInstMeasured, $mineMiB, $perInstDerived, `
        $commitUsed, $commitLimit, $physUsed, $physTotal, ($priv/1GB), $peak |
        Add-Content -LiteralPath $CsvPath -Encoding Ascii

    Start-Sleep -Seconds $IntervalSeconds
}

""
"done. peak instances $peak, peak VRAM $peakVram MiB of $vramTotal MiB"
if ($peakMeasured -gt 0) {
    "peak measured per-instance: {0:N0} MiB" -f $peakMeasured
}
"csv: $CsvPath"
