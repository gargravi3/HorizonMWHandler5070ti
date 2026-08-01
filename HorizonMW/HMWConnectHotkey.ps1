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

    # How to deliver the command. Post*/BindKey use window messages and need no
    # focus. Keys*/FocusBindKey bring each window to the foreground and use
    # SendKeys. *Toggle sends the console toggle key before and after the command.
    [ValidateSet('FocusBindKey', 'BindKey', 'PostToggle', 'PostNoToggle', 'KeysToggle', 'KeysNoToggle')]
    [string]$Variant,

    # Assert the guest selection logic against synthetic data, then exit.
    [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'

# The variant the F2 hotkey uses.
#
# KeysToggle, because it is the only one observed connecting guests. Proven with
# three instances: it opened the console in both guests, typed the connect command
# and both joined. Each guest also rewrote its own config_mp.cfg in the same
# second, which is independent evidence the input landed.
#
# BindKey is the counter-example and the reason this is now chosen on evidence
# rather than design. It posts WM_KEYDOWN/WM_KEYUP directly to each window and
# needs no focus, which is much tidier, and with the lParam overflow fixed it
# reports successful delivery to every guest. The guests still do not connect.
# That is exactly what happens when a game reads the keyboard through raw input
# or DirectInput: neither API looks at a window's message queue, so a posted key
# is invisible no matter how correctly it is formed. It was made the default once
# on the strength of the idea alone, and never worked once.
#
# FocusBindKey is the variant worth having: the F3 bind, so no console and no
# typing, delivered as a real synthesized keystroke, which is the part that
# demonstrably reaches the game. It is deliberately NOT the default yet, because
# it has not been observed connecting a guest, and promoting an unverified variant
# is the mistake that cost four sessions of debugging. Prove it with
# -TestConnect -Variant FocusBindKey, then promote it.
$DefaultVariant = 'KeysToggle'

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

# A key message's lParam is pointer-sized, but every flag lives in its low 32
# bits, and a key *release* sets the top two of those (0xC0000000). For F3 the
# result is a UInt32 of 3225223169, and casting that straight to IntPtr is what
# broke every BindKey join:
#
#   64-bit PowerShell : [IntPtr]3225223169 succeeds
#   32-bit PowerShell : throws "Arithmetic operation resulted in an overflow"
#
# IntPtr is 4 bytes there and the conversion runs through a checked Int32.
# NucleusCoop.exe is x86, so the powershell.exe it starts is redirected to
# SysWOW64 and is always the 32-bit one. The bug could therefore only ever appear
# in production, never in a test run from an ordinary 64-bit shell.
#
# It also failed in the worst direction: both lParams are computed before the
# first PostMessage call, so nothing was ever posted, and the throw escaped to the
# watcher's top-level handler and abandoned the remaining guests. The log line
# "join failed: Cannot convert value 3225223169 to type System.IntPtr" is this
# bug, not the game refusing posted input.
#
# $PointerSize is injectable so the self test can exercise both widths from either
# host. Defined above the -SelfTest block so the self test can reach it, since it
# needs no P/Invoke; Send-KeyMessage, which does, stays in the win32 section.
function New-KeyLParam([uint32]$Bits, [int]$PointerSize = [IntPtr]::Size) {
    if ($PointerSize -eq 8) { return [IntPtr][int64]$Bits }
    # Reinterpret the identical bit pattern as a signed int so that it fits.
    return [IntPtr][BitConverter]::ToInt32([BitConverter]::GetBytes($Bits), 0)
}

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

    ''
    "key lParam construction (this host: IntPtr is $([IntPtr]::Size) bytes)"
    # 0xC03D0001 is the genuine F3 key-release lParam: repeat count 1, scancode
    # 0x3D, plus the transition and previous-state bits. It is the exact value
    # that made every join fail.
    #
    # It has to be built with Convert rather than written as [uint32]0xC03D0001,
    # because PowerShell parses an 8-digit hex literal as a *signed* Int32, so
    # that cast throws before the test can even run. Masks have the same trap:
    # 0xFFFFFFFF parses as -1, which is why the mask below is built from
    # [uint32]::MaxValue instead.
    $keyUpBits   = [Convert]::ToUInt32('C03D0001', 16)
    $keyDownBits = [Convert]::ToUInt32('003D0001', 16)
    $low32       = [int64][uint32]::MaxValue

    Assert 'release lParam builds on this host'     { (New-KeyLParam $keyUpBits) -is [IntPtr] }
    # The 32-bit branch is the one production always takes, and it is also valid
    # on a 64-bit host, so it is checked unconditionally.
    Assert 'release lParam correct, 32-bit branch'  {
        ([int64](New-KeyLParam $keyUpBits 4) -band $low32) -eq $keyUpBits
    }
    Assert 'press lParam correct, 32-bit branch'    {
        ([int64](New-KeyLParam $keyDownBits 4) -band $low32) -eq $keyDownBits
    }
    # The reverse is not true: [IntPtr][int64]3225223169 overflows in a 32-bit
    # process, so the 64-bit branch simply cannot be exercised from there. Claiming
    # to test it anyway is how the original bug slipped through, so skip it openly.
    if ([IntPtr]::Size -eq 8) {
        Assert 'release lParam correct, 64-bit branch' {
            ([int64](New-KeyLParam $keyUpBits 8) -band $low32) -eq $keyUpBits
        }
        Assert 'press lParam correct, 64-bit branch'   {
            ([int64](New-KeyLParam $keyDownBits 8) -band $low32) -eq $keyDownBits
        }
    } else {
        '  SKIP  64-bit branch is not reachable from a 32-bit host'
    }
    # Non-vacuous, and the reason this bug survived: the cast being replaced only
    # throws where IntPtr is 4 bytes. Assert the behaviour this host can actually
    # observe, so the check is a real one on both rather than vacuous on one.
    Assert 'the old cast is unusable at this width' {
        $threw = $false
        try { $null = [IntPtr]$keyUpBits } catch { $threw = $true }
        if ([IntPtr]::Size -eq 4) { $threw } else { -not $threw }
    }
    # The watcher and the handler must agree on which key carries the connect
    # command, or the keypress lands on an unbound key and nothing happens.
    Assert 'F3 constant matches its virtual key'    { $ConnectBindKey -eq 'F3' -and $VK_CONNECT_BIND -eq 0x72 }
    # MapVirtualKey supplies the scancode at runtime; if F3 ever stopped mapping
    # to 0x3D the lParam above would no longer describe the key being sent.
    Assert 'F3 maps to scancode 0x3D'               {
        Add-Type -Namespace HMWT -Name Map -MemberDefinition '[DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);' -ErrorAction SilentlyContinue
        [HMWT.Map]::MapVirtualKey($VK_CONNECT_BIND, 0) -eq 0x3D
    }

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
    $down = New-KeyLParam ([uint32](1 -bor ($scan -shl 16)))
    $up   = New-KeyLParam ([uint32](1 -bor ($scan -shl 16) -bor 0xC0000000))
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

    # Neither BindKey variant uses $Command: the handler has already bound the
    # whole connect command to $ConnectBindKey in the guest's keys_mp.cfg, so a
    # single keypress is the entire delivery, with no console to toggle, no text
    # to type and no ENTER.
    #
    # FocusBindKey takes focus and sends a real synthesized keystroke. BindKey
    # posts the key to the window instead and skips focus entirely, which is
    # tidier but does not work: the game ignores posted keys.
    if ($Mode -eq 'FocusBindKey') {
        if (-not (Set-WindowForeground $Handle)) {
            Write-Log '    could not focus window, skipping'
            return
        }
        # Braced token derived from $ConnectBindKey so the key sent here can never
        # drift from the key the handler bound.
        [System.Windows.Forms.SendKeys]::SendWait('{' + $ConnectBindKey + '}')
        Start-Sleep -Milliseconds 750
        return
    }
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
            return $false
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
    return $true
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
    $delivered = 0
    foreach ($g in $guests) {
        Write-Log "  instance $($g.Index) pid $($g.ProcessId) hwnd $($g.Handle)"
        # One guest must not be able to abandon the others. The lParam overflow
        # threw on the first guest and took the whole loop with it, so instance 2
        # was never even attempted.
        # Count only what actually went out. Counting every call that failed to
        # throw logged "delivered to 2 of 2" for guests that were skipped because
        # their window could not be focused, which is how I came to believe a
        # keypress had been delivered when nothing had been sent at all.
        try {
            if (Send-ConnectCommand -Handle $g.Handle -Command $command -Mode $Mode) { $delivered++ }
        } catch {
            Write-Log "  instance $($g.Index) delivery failed: $($_.Exception.Message)"
        }
    }
    Write-Log "done, delivered to $delivered of $($guests.Count) guest(s)"
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
# The pointer width is worth recording: Nucleus is x86, so this is normally the
# 32-bit PowerShell, and that difference is what made the lParam overflow show up
# only in real sessions.
Write-Log ("watcher started, pid $PID, variant $mode, " +
    "$([IntPtr]::Size * 8)-bit host, PowerShell $($PSVersionTable.PSVersion)")

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
