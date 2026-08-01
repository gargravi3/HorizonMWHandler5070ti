# ---------------------------------------------------------------------------
# HorizonMW host-join watcher for the Nucleus Co-op HorizonMW handler.
#
# HMW has no command line "connect on launch" option, so guests are joined by
# driving the in-game console. Started by the handler for instance 0 only.
#
# Press F2 once the host has created a private/custom match: every guest
# instance is sent "connect 127.0.0.1:27016".
#
# Confirmed working sequence, per guest, in order:
#   bring the guest window to the foreground and verify it really is foreground
#   {~}                        open the console
#   connect 127.0.0.1:27016    type the command
#   {ENTER}                    run it
#   {~}                        close the console
# That is the KeysToggle variant and it is the default. The Post* variants use
# posted window messages instead and need no focus change, mirroring the AutoIt
# ControlSend approach in birden's MWR handler; they are kept as alternates.
#
# Only guests are touched. Instance0 is the host and is always excluded, since
# it must not be told to connect to itself. Guests never connect to their own
# port: the handler gives instance N port 27016 + N*2, and every guest connects
# to the host's 27016.
#
# These shortcuts only work while Nucleus input is unlocked. Once input is
# locked, ProtoInput's keyboard and message filters swallow the input.
#
# Iterating on this without relaunching Nucleus:
#     powershell -NoProfile -STA -File HMWConnectHotkey.ps1 -TestConnect
#     powershell -NoProfile -STA -File HMWConnectHotkey.ps1 -TestConnect -Variant KeysToggle
# Run that while the instances are up and read %TEMP%\HMWConnectHotkey.log.
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    # Fire one connect attempt immediately and exit, instead of watching for F2.
    [switch]$TestConnect,

    # How to deliver the command. Post* uses window messages and needs no focus.
    # Keys* brings each window to the foreground and uses SendKeys.
    # *Toggle sends the console toggle key before and after the command.
    [ValidateSet('BindKey', 'PostToggle', 'PostNoToggle', 'KeysToggle', 'KeysNoToggle')]
    [string]$Variant,

    # Assert the guest selection logic against synthetic data, then exit.
    [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'

# The variant the F2 hotkey uses. KeysToggle is the one confirmed working.
# BindKey: press the one key the handler bound the connect command to. This is
# the default because KeysToggle, which was reliable with a single guest, failed
# with two. KeysToggle uses SendKeys, which goes to whatever window is in the
# foreground, so it has to steal focus per guest and type a whole command; that
# got much less reliable once Game.SupportsMultipleKeyboardsAndMice was turned
# off and Nucleus stopped installing its keyboard hook layer. BindKey posts a
# single message straight to each guest's window handle and never touches focus.
# KeysToggle is kept as a fallback: pass -Variant KeysToggle.
$DefaultVariant = 'BindKey'

$HostPort      = 27016
$PollMs        = 100
$ScanEverySec  = 2
$IdleExitSec   = 30    # exit this long after the last hmw-mod.exe disappears
$StartupGrace  = 300   # exit if no hmw-mod.exe ever shows up within this long
$LogPath       = Join-Path $env:TEMP 'HMWConnectHotkey.log'
$StopSentinel  = Join-Path $env:TEMP 'HMWConnectHotkey.stop'
$HmwAppData    = Join-Path $env:LOCALAPPDATA 'hmw-mod'
$IdentityFiles = @('hwgd.pf', 'hmw-key', 'hmw-key.pub')
$BackupSuffix  = '.nucleus-original'

$VK_F2      = 0x71
$VK_RETURN  = 0x0D
$VK_OEM_3   = 0xC0   # the `/~ key, which toggles the HMW console
# The key the handler binds "connect 127.0.0.1:27016" to inside each guest.
# Must match HMW_CONNECT_BIND_KEY in HorizonMW.js. F3 = 0x72, F1/F2 are taken by
# the game's own discord_accept / discord_deny binds.
$ConnectBindKey  = 'F3'
$VK_CONNECT_BIND = 0x72
$WM_KEYDOWN = 0x0100
$WM_KEYUP   = 0x0101
$WM_CHAR    = 0x0102
$SW_RESTORE = 9

function Write-Log([string]$Message) {
    try {
        "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message |
            Out-File -FilePath $LogPath -Append -Encoding utf8
    } catch { }
}

# --- guest selection -------------------------------------------------------
# Kept free of side effects so -SelfTest can drive it with synthetic data.
# Emits objects one at a time; never "return ,$array", which wraps the array so
# that @(Select-HmwGuest ...) collects one nested item instead of N objects.

function Select-HmwGuest {
    param([object[]]$ProcessInfo)

    if (-not $ProcessInfo) { return }

    $matched = foreach ($p in $ProcessInfo) {
        $path = $p.ExecutablePath
        if (-not $path) { continue }
        if ($path -notmatch '\\Instance(\d+)\\') { continue }
        $index = [int]$Matches[1]
        if ($index -eq 0) { continue }   # instance 0 is the host, never a guest
        [pscustomobject]@{
            Index          = $index
            ProcessId      = [int]$p.ProcessId
            ExecutablePath = $path
        }
    }

    if (-not $matched) { return }
    $matched | Sort-Object Index
}

function Get-HmwProcessInfo {
    try {
        @(Get-CimInstance Win32_Process -Filter "Name = 'hmw-mod.exe'" -ErrorAction SilentlyContinue)
    } catch {
        @()
    }
}

function Get-HmwGuestWindow {
    $info = Get-HmwProcessInfo
    $guests = @(Select-HmwGuest -ProcessInfo $info)

    if ($guests.Count -eq 0 -and $info.Count -gt 1) {
        # ExecutablePath can be unreadable; fall back to every window except the
        # oldest, which is the host.
        Write-Log 'no guest matched by path, falling back to process start order'
        $guests = @(
            Get-Process hmw-mod -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
                Sort-Object StartTime | Select-Object -Skip 1 |
                ForEach-Object {
                    [pscustomobject]@{ Index = -1; ProcessId = $_.Id; ExecutablePath = '<unknown>' }
                }
        )
    }

    foreach ($g in $guests) {
        $proc = Get-Process -Id $g.ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        if ($proc.MainWindowHandle -eq [IntPtr]::Zero) {
            Write-Log "  instance $($g.Index) pid $($g.ProcessId) has no window yet, skipping"
            continue
        }
        [pscustomobject]@{
            Index     = $g.Index
            ProcessId = $g.ProcessId
            Handle    = $proc.MainWindowHandle
        }
    }
}

# --- self test -------------------------------------------------------------

if ($SelfTest) {
    $fail = 0
    function Assert([string]$name, [scriptblock]$test) {
        $ok = $false
        try { $ok = [bool](& $test) } catch { $ok = $false }
        if ($ok) { "  PASS  $name" } else { "  FAIL  $name"; $script:fail++ }
    }

    $sample = @(
        [pscustomobject]@{ ExecutablePath = 'C:\NucleusCoop\content\HorizonMW\Instance1\hmw-mod.exe';  ProcessId = 111 }
        [pscustomobject]@{ ExecutablePath = 'C:\NucleusCoop\content\HorizonMW\Instance0\hmw-mod.exe';  ProcessId = 100 }
        [pscustomobject]@{ ExecutablePath = 'C:\NucleusCoop\content\HorizonMW\Instance10\hmw-mod.exe'; ProcessId = 110 }
        [pscustomobject]@{ ExecutablePath = 'C:\NucleusCoop\content\HorizonMW\Instance2\hmw-mod.exe';  ProcessId = 222 }
        [pscustomobject]@{ ExecutablePath = 'C:\Games\HorizonMW\hmw-mod.exe';                          ProcessId = 999 }
        [pscustomobject]@{ ExecutablePath = $null;                                                     ProcessId = 888 }
    )
    $got = @(Select-HmwGuest -ProcessInfo $sample)

    'Select-HmwGuest self test'
    Assert 'returns a flat array of 3 guests'   { $got.Count -eq 3 }
    # The regression: a wrapped array makes $got[0].Index enumerate to several values.
    Assert 'each item is a single object'       { -not ($got[0].Index -is [array]) -and -not ($got[0].ProcessId -is [array]) }
    Assert 'instance 0 is excluded'             { @($got | Where-Object { $_.Index -eq 0 }).Count -eq 0 }
    Assert 'host pid 100 is excluded'           { @($got | Where-Object { $_.ProcessId -eq 100 }).Count -eq 0 }
    Assert 'non-instance path excluded'         { @($got | Where-Object { $_.ProcessId -eq 999 }).Count -eq 0 }
    Assert 'null path excluded'                 { @($got | Where-Object { $_.ProcessId -eq 888 }).Count -eq 0 }
    Assert 'sorted numerically 1,2,10'          { ($got | ForEach-Object { $_.Index }) -join ',' -eq '1,2,10' }
    Assert 'index is an int'                    { $got[0].Index -is [int] }
    Assert 'single guest still yields an array' {
        @(Select-HmwGuest -ProcessInfo @($sample[0])).Count -eq 1
    }
    Assert 'no input yields an empty array'     { @(Select-HmwGuest -ProcessInfo @()).Count -eq 0 }
    Assert 'host only yields an empty array'    { @(Select-HmwGuest -ProcessInfo @($sample[1])).Count -eq 0 }

    if ($fail -gt 0) { "$fail check(s) failed"; exit 1 }
    'all checks passed'
    exit 0
}

# --- win32 -----------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace HMW -Name Win -MemberDefinition @'
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
'@

function Send-KeyMessage([IntPtr]$Handle, [int]$VirtualKey) {
    $scan = [HMW.Win]::MapVirtualKey([uint32]$VirtualKey, 0)
    $down = [IntPtr](1 -bor ($scan -shl 16))
    $up   = [IntPtr](1 -bor ($scan -shl 16) -bor 0xC0000000)
    [void][HMW.Win]::PostMessage($Handle, $WM_KEYDOWN, [IntPtr]$VirtualKey, $down)
    Start-Sleep -Milliseconds 40
    [void][HMW.Win]::PostMessage($Handle, $WM_KEYUP, [IntPtr]$VirtualKey, $up)
}

function Send-TextMessage([IntPtr]$Handle, [string]$Text) {
    foreach ($ch in $Text.ToCharArray()) {
        [void][HMW.Win]::PostMessage($Handle, $WM_CHAR, [IntPtr][int][char]$ch, [IntPtr]1)
        Start-Sleep -Milliseconds 20
    }
}

# Windows resists foreground changes; tapping Alt releases the lock.
function Set-WindowForeground([IntPtr]$Handle) {
    for ($i = 0; $i -lt 8; $i++) {
        [void][HMW.Win]::ShowWindowAsync($Handle, $SW_RESTORE)
        [void][HMW.Win]::SetForegroundWindow($Handle)
        Start-Sleep -Milliseconds 250
        if ([HMW.Win]::GetForegroundWindow() -eq $Handle) {
            Start-Sleep -Milliseconds 350
            return $true
        }
        if ($i -eq 2) {
            [System.Windows.Forms.SendKeys]::SendWait('%')
            Start-Sleep -Milliseconds 100
        }
    }
    return $false
}

function Send-ConnectCommand {
    param([IntPtr]$Handle, [string]$Command, [string]$Mode)

    # BindKey does not use $Command at all. The handler has already bound the
    # whole connect command to $ConnectBindKey inside the guest's keys_mp.cfg,
    # so one posted keypress is the entire delivery: no console to toggle, no
    # text to type, no ENTER, and no focus to steal.
    if ($Mode -eq 'BindKey') {
        Send-KeyMessage $Handle $VK_CONNECT_BIND
        Start-Sleep -Milliseconds 750
        return
    }

    $useMessages  = $Mode -like 'Post*'
    $toggleConsole = $Mode -like '*Toggle'

    if ($useMessages) {
        if ($toggleConsole) { Send-KeyMessage $Handle $VK_OEM_3; Start-Sleep -Milliseconds 500 }
        Send-TextMessage $Handle $Command
        Start-Sleep -Milliseconds 200
        Send-KeyMessage $Handle $VK_RETURN
        Start-Sleep -Milliseconds 1000
        if ($toggleConsole) { Send-KeyMessage $Handle $VK_OEM_3 }
    } else {
        # Sending into the wrong window would type the command into whatever is
        # focused, so give up on this guest rather than guess.
        if (-not (Set-WindowForeground $Handle)) {
            Write-Log '    could not focus window, skipping'
            return
        }
        # {~} is a literal tilde; a bare ~ would mean ENTER to SendKeys.
        if ($toggleConsole) { [System.Windows.Forms.SendKeys]::SendWait('{~}'); Start-Sleep -Milliseconds 500 }
        [System.Windows.Forms.SendKeys]::SendWait($Command)
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Start-Sleep -Milliseconds 1000
        if ($toggleConsole) { [System.Windows.Forms.SendKeys]::SendWait('{~}') }
    }
    Start-Sleep -Milliseconds 750
}

function Invoke-HostJoin([string]$Mode) {
    $command = "connect 127.0.0.1:$HostPort"
    $guests = @(Get-HmwGuestWindow)
    if ($guests.Count -eq 0) {
        Write-Log 'no guest instances with a window were found'
        return
    }
    Write-Log ("connecting $($guests.Count) guest(s) using $Mode" + ": instances " +
        (($guests | ForEach-Object { $_.Index }) -join ', '))
    foreach ($g in $guests) {
        Write-Log "  instance $($g.Index) pid $($g.ProcessId) hwnd $($g.Handle)"
        Send-ConnectCommand -Handle $g.Handle -Command $command -Mode $Mode
    }
    Write-Log 'done'
}

# Repeated Nucleus sessions must not stack watchers.
function Stop-PreviousWatchers {
    $me = $PID
    try {
        # Require -File so this only ever matches a real watcher launch, not some
        # other shell that merely mentions the script name on its command line.
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $me -and
                $_.CommandLine -like '*-File*' -and
                $_.CommandLine -like '*HMWConnectHotkey.ps1*'
            } |
            ForEach-Object {
                Write-Log "killing previous watcher pid $($_.ProcessId)"
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    } catch { }
}

# Only for the case where the session ended without Game.OnStop running. Doing
# this on any other exit path restored the identity mid-session.
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

function Wait-F2Release {
    $deadline = (Get-Date).AddSeconds(3)
    while ((([HMW.Win]::GetAsyncKeyState($VK_F2) -band 0x8000) -ne 0) -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Milliseconds 50
    }
    Start-Sleep -Milliseconds 350
}

# --- manual test mode ------------------------------------------------------

if ($TestConnect) {
    $mode = if ($Variant) { $Variant } else { $DefaultVariant }
    Write-Log "=== -TestConnect, variant $mode"
    Invoke-HostJoin $mode
    Get-Content -LiteralPath $LogPath -Tail 20
    exit 0
}

# --- main loop -------------------------------------------------------------

$mode = if ($Variant) { $Variant } else { $DefaultVariant }

Stop-PreviousWatchers
Write-Log "watcher started, pid $PID, variant $mode"

$wasDown  = $false
$seenGame = $false
$lastSeen = Get-Date
$started  = Get-Date
$nextScan = Get-Date
$gameGone = $false

try {
    while ($true) {
        if (Test-Path -LiteralPath $StopSentinel) {
            Write-Log 'stop sentinel found'
            break
        }

        # Act on the up-to-down transition, not on the held state, and let the
        # key go before sending anything so it cannot mix into the input.
        $isDown = ([HMW.Win]::GetAsyncKeyState($VK_F2) -band 0x8000) -ne 0
        if ($isDown -and -not $wasDown) {
            Wait-F2Release
            try { Invoke-HostJoin $mode } catch { Write-Log "join failed: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 800
        }
        # Leave $wasDown true while the key is still reported down, so a long
        # press cannot start the sequence a second time.
        $wasDown = $isDown

        # A process scan is comparatively expensive, so do it far less often
        # than the key poll.
        if ((Get-Date) -ge $nextScan) {
            $nextScan = (Get-Date).AddSeconds($ScanEverySec)
            $running = @(Get-Process hmw-mod -ErrorAction SilentlyContinue).Count
            if ($running -gt 0) {
                $seenGame = $true
                $lastSeen = Get-Date
            } elseif ($seenGame) {
                if (((Get-Date) - $lastSeen).TotalSeconds -gt $IdleExitSec) {
                    Write-Log 'no hmw-mod.exe for a while, exiting'
                    $gameGone = $true
                    break
                }
            } elseif (((Get-Date) - $started).TotalSeconds -gt $StartupGrace) {
                Write-Log 'game never appeared, exiting'
                break
            }
        }

        Start-Sleep -Milliseconds $PollMs
    }
} catch {
    # Never restore identity from here: an exception mid-session would put the
    # real keypair back while the instances are still running.
    Write-Log "watcher error: $($_.Exception.Message)"
} finally {
    if ($gameGone) { Restore-HmwIdentity }
    Remove-Item -LiteralPath $StopSentinel -Force -ErrorAction SilentlyContinue
    Write-Log "watcher exiting, pid $PID"
}
