# ---------------------------------------------------------------------------
# HorizonMW host-join watcher for the Nucleus Co-op HorizonMW handler.
#
# HMW has no command line "connect on launch" option, so guests are joined by
# driving the in-game console. Started by the handler for instance 0 only.
#
# Press F2 once the host has created a private/custom match: every guest
# instance is brought to the foreground in turn and sent
# "connect 127.0.0.1:27016" through its console.
#
# Exits by itself when the session ends, and restores the user's real HorizonMW
# identity files on the way out in case Nucleus' own teardown did not run.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Continue'

$HostPort       = 27016
$PollMs         = 100
$IdleExitSec    = 30    # exit this long after the last hmw-mod.exe disappears
$StartupGrace   = 300   # exit if no hmw-mod.exe ever shows up within this long
$LogPath        = Join-Path $env:TEMP 'HMWConnectHotkey.log'
$StopSentinel   = Join-Path $env:TEMP 'HMWConnectHotkey.stop'
$HmwAppData     = Join-Path $env:LOCALAPPDATA 'hmw-mod'
$IdentityFiles  = @('hwgd.pf', 'hmw-key', 'hmw-key.pub')
$BackupSuffix   = '.nucleus-original'

function Write-Log([string]$Message) {
    try {
        "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message | Out-File -FilePath $LogPath -Append -Encoding utf8
    } catch { }
}

# Repeated Nucleus sessions must not stack watchers.
function Stop-PreviousWatchers {
    $me = $PID
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*HMWConnectHotkey.ps1*' } |
            ForEach-Object {
                Write-Log "killing previous watcher pid $($_.ProcessId)"
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    } catch { }
}

# Idempotent, and deliberately also done by Game.OnStop in the handler.
function Restore-HmwIdentity {
    foreach ($name in $IdentityFiles) {
        $live = Join-Path $HmwAppData $name
        $bak  = "$live$BackupSuffix"
        if (Test-Path -LiteralPath $bak) {
            try {
                Copy-Item -LiteralPath $bak -Destination $live -Force
                Remove-Item -LiteralPath $bak -Force
                Write-Log "restored $name"
            } catch {
                Write-Log "restore failed for ${name}: $($_.Exception.Message)"
            }
        }
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace HMW -Name Win -MemberDefinition @'
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
'@

$VK_F2      = 0x71
$SW_RESTORE = 9

function Get-HmwInstances {
    $result = @()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='hmw-mod.exe'" -ErrorAction SilentlyContinue
    } catch {
        $procs = @()
    }
    foreach ($p in $procs) {
        $path = $p.ExecutablePath
        if (-not $path) { continue }
        if ($path -match '\\Instance(\d+)\\') {
            $idx = [int]$Matches[1]
        } else {
            continue
        }
        $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        $handle = if ($gp) { $gp.MainWindowHandle } else { [IntPtr]::Zero }
        $result += [pscustomobject]@{
            Index  = $idx
            Id     = $p.ProcessId
            Handle = $handle
        }
    }
    ,($result | Sort-Object Index)
}

# Windows resists foreground changes, so retry for a short while.
function Set-WindowForeground([IntPtr]$Handle) {
    for ($i = 0; $i -lt 12; $i++) {
        [void][HMW.Win]::ShowWindowAsync($Handle, $SW_RESTORE)
        [void][HMW.Win]::SetForegroundWindow($Handle)
        Start-Sleep -Milliseconds 120
        if ([HMW.Win]::GetForegroundWindow() -eq $Handle) { return $true }
    }
    return $false
}

function Send-ConnectCommand([IntPtr]$Handle) {
    if (-not (Set-WindowForeground $Handle)) {
        Write-Log "could not focus window $Handle, sending anyway"
    }
    # {~} is a literal tilde; a bare ~ would mean ENTER to SendKeys.
    # The console drops input if the steps are sent back to back.
    [System.Windows.Forms.SendKeys]::SendWait('{~}')
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.SendKeys]::SendWait("connect 127.0.0.1:$HostPort")
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.SendKeys]::SendWait('{~}')
    Start-Sleep -Milliseconds 300
}

function Invoke-HostJoin {
    $all = @(Get-HmwInstances)
    $guests = @($all | Where-Object { $_.Index -ne 0 -and $_.Handle -ne [IntPtr]::Zero })
    if ($guests.Count -eq 0) {
        Write-Log 'F2 pressed but no guest instances with a window were found'
        return
    }
    Write-Log ("F2: connecting guests " + (($guests | ForEach-Object { $_.Index }) -join ', '))
    foreach ($g in $guests) {
        Write-Log "  instance $($g.Index) pid $($g.Id)"
        Send-ConnectCommand $g.Handle
    }
    # Hand focus back to the host so the match can be started.
    $hostInst = $all | Where-Object { $_.Index -eq 0 -and $_.Handle -ne [IntPtr]::Zero } | Select-Object -First 1
    if ($hostInst) { [void](Set-WindowForeground $hostInst.Handle) }
    Write-Log 'F2: done'
}

# --- main loop --------------------------------------------------------------

Stop-PreviousWatchers
Write-Log "watcher started, pid $PID"

$wasDown       = $false
$seenGame      = $false
$lastSeen      = Get-Date
$started       = Get-Date
$nextScan      = Get-Date

try {
    while ($true) {
        if (Test-Path -LiteralPath $StopSentinel) {
            Write-Log 'stop sentinel found'
            break
        }

        # Act on the up-to-down transition, not on the held state.
        $isDown = ([HMW.Win]::GetAsyncKeyState($VK_F2) -band 0x8000) -ne 0
        if ($isDown -and -not $wasDown) {
            Invoke-HostJoin
        }
        $wasDown = $isDown

        # The process scan is a WMI query, so run it far less often than the key poll.
        if ((Get-Date) -ge $nextScan) {
            $nextScan = (Get-Date).AddSeconds(2)
            $running = @(Get-HmwInstances).Count
            if ($running -gt 0) {
                $seenGame = $true
                $lastSeen = Get-Date
            } elseif ($seenGame) {
                if (((Get-Date) - $lastSeen).TotalSeconds -gt $IdleExitSec) {
                    Write-Log 'no hmw-mod.exe for a while, exiting'
                    break
                }
            } elseif (((Get-Date) - $started).TotalSeconds -gt $StartupGrace) {
                Write-Log 'game never appeared, exiting'
                break
            }
        }

        Start-Sleep -Milliseconds $PollMs
    }
} finally {
    Restore-HmwIdentity
    Remove-Item -LiteralPath $StopSentinel -Force -ErrorAction SilentlyContinue
    Write-Log "watcher exiting, pid $PID"
}
