<#
    Diagnose-InstanceColour.ps1

    Instance 1 renders the map Rust noticeably warmer and darker than instances
    2-4, which agree with each other. This turns that observation into numbers and
    then finds the dvar responsible by experiment.

    Why a script rather than reading a config: every per-instance file has already
    been eliminated. All four config_mp.cfg hold 309 identical dvars, differing
    only in "name" and "vid_xpos"; a whole-tree diff of 14,585 files showed only
    the expected per-player files; settings_m.zip.h1 is byte-identical across all
    four and settings_c.zip.h1 turned out to be controller bindings, not a zip.
    HorizonMW persists no gamma, brightness or film-tweak dvar to disk at all, so
    the difference exists only at runtime and only a live measurement can see it.

    The console is not a usable channel here. hmw-mod.exe contains neither
    "toggleconsole" nor "com_allowConsole", and h1_mp64_ship.exe carries none of
    the dvar strings that demonstrably work, so its strings are packed and absence
    proves nothing either way. Binds are the proven channel in this project: the
    handler already writes bind F3 "connect ..." and the F2 watcher delivers real
    synthesized keystrokes to a chosen window. Binds are read at startup, so all
    candidates are armed before launch and A/B tested within one session.

    Nothing here is installed into Nucleus. install.ps1 mirrors only its eight
    asset files, so this script is reachable only from the repository. Captures and
    backups live under %TEMP%\hmw-colour. -Cleanup restores every file it touched
    and deletes them, after which deleting this one file removes the feature.

        -SelfTest     verify the measurement maths and the cleanup, no game needed
        -Arm          back up configs and binds, then arm the candidate binds
        -Measure      capture all four slices and report colour statistics
        -FocusSweep   focus each instance in turn and measure all four each time
        -Press F5     send one candidate to an instance, default instance 1
        -Cleanup      restore backed-up files and delete captures
#>

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Arm,
    [switch]$Measure,
    [switch]$FocusSweep,
    [string]$Press,
    [int]$Instance = 1,
    [switch]$Cleanup,
    [string]$ContentRoot = 'C:\NucleusCoop\content\HorizonMW',
    [string]$WorkRoot = (Join-Path $env:TEMP 'hmw-colour'),
    [string]$Label = ''
)

$ErrorActionPreference = 'Stop'

# Each candidate is one hypothesis, keyed by the function key that applies it.
# Ordered so the cheapest and most likely lever is pressed first. Every dvar named
# here was confirmed present in hmw-mod.exe by a string scan; r_gamma is absent
# from the binary and deliberately not probed.
$Probes = [ordered]@{
    'F5'  = 'r_filmUseTweaks 0'
    'F6'  = 'r_colorScaleUseTweaks 0'
    'F7'  = 'r_filmTweakBrightness 0; r_filmTweakContrast 1; r_filmTweakDesaturation 0'
    'F8'  = 'r_tonemap 0'
    'F9'  = 'visionsetnaked default 0'
    # Control. Without it, a candidate that changes nothing is indistinguishable
    # from a keystroke that never arrived: same measurement, opposite meaning.
    # cg_infobar_fps is the one dvar already proven to work from this handler, and
    # switching the FPS readout off is unmissable both on screen and in a capture.
    'F10' = 'cg_infobar_fps 0'
}

# The bind lines themselves carry no trailing comment. Whether this parser accepts
# a mid-line "//" is unverified, and a rejected bind line would make every press do
# nothing while looking exactly like a dvar that has no effect. So probe binds are
# written in the identical shape to the handler's proven F3 connect bind, and the
# marker goes on its own comment line, which cfg files demonstrably do accept.
$ProbeMarker = '// hmw-colour-probe'

# Cleanup identifies probes by these keys rather than by a marker on the bind line.
# Restricting it to the probe keys is what keeps the handler's F3 bind and the
# game's own F1/F2 Discord binds safe.
$ProbeKeyPattern = '^\s*bind\s+(F5|F6|F7|F8|F9|F10)\s'

$BackupRoot  = Join-Path $WorkRoot 'backup'
$CaptureRoot = Join-Path $WorkRoot 'captures'

function Write-Head([string]$Text) { Write-Host ""; Write-Host "=== $Text ===" }

# --- measurement ------------------------------------------------------------

# Statistics over the centre of a slice. The HUD, killfeed and minimap live at the
# edges and are strongly coloured, so they would swamp a mean taken over the whole
# window; the centre 60% is mostly world. R:B is the useful figure because "more
# orange" is precisely red gaining on blue, and it survives an overall brightness
# change that would move all three channels together.
function Measure-Region {
    param([System.Drawing.Bitmap]$Bitmap, [System.Drawing.Rectangle]$Rect, [double]$CentreFraction = 0.6)

    $inset = (1.0 - $CentreFraction) / 2.0
    $x0 = [int]($Rect.X + $Rect.Width  * $inset)
    $y0 = [int]($Rect.Y + $Rect.Height * $inset)
    $x1 = [int]($Rect.X + $Rect.Width  * (1.0 - $inset))
    $y1 = [int]($Rect.Y + $Rect.Height * (1.0 - $inset))

    # Upper bounds are exclusive: with a 60% crop of 200 px the region is 40..159,
    # not 40..160, so a feature that starts exactly at the 80% mark stays outside.
    $x0 = [Math]::Max(0, $x0); $y0 = [Math]::Max(0, $y0)
    $x1 = [Math]::Min($Bitmap.Width  - 1, $x1 - 1)
    $y1 = [Math]::Min($Bitmap.Height - 1, $y1 - 1)

    $sumR = 0.0; $sumG = 0.0; $sumB = 0.0; $n = 0
    $step = 4        # every 4th pixel: ~9k samples per slice, plenty for a mean
    for ($y = $y0; $y -le $y1; $y += $step) {
        for ($x = $x0; $x -le $x1; $x += $step) {
            $p = $Bitmap.GetPixel($x, $y)
            $sumR += $p.R; $sumG += $p.G; $sumB += $p.B; $n++
        }
    }
    if ($n -eq 0) { return $null }

    $r = $sumR / $n; $g = $sumG / $n; $b = $sumB / $n
    [pscustomobject]@{
        Samples   = $n
        R         = [Math]::Round($r, 2)
        G         = [Math]::Round($g, 2)
        B         = [Math]::Round($b, 2)
        # Rec. 709 luma, the standard weighting for perceived brightness.
        Luma      = [Math]::Round(0.2126 * $r + 0.7152 * $g + 0.0722 * $b, 2)
        RtoB      = if ($b -gt 0.001) { [Math]::Round($r / $b, 4) } else { [double]::NaN }
        RtoG      = if ($g -gt 0.001) { [Math]::Round($r / $g, 4) } else { [double]::NaN }
    }
}

# --- win32 ------------------------------------------------------------------

function Initialize-Win32 {
    if (-not ('HMWColour.Win' -as [type])) {
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -Namespace HMWColour -Name Win -MemberDefinition @'
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
    }
    # Without this the window rectangles and the screen capture can be expressed in
    # different coordinate spaces on a scaled display, and every slice would be
    # cropped from slightly the wrong place.
    [void][HMWColour.Win]::SetProcessDPIAware()
}

# Instance identity comes from the executable path, which is how the F2 watcher
# does it, because start order is only a fallback: ExecutablePath can be
# unreadable, and process start times are close enough together to be fragile.
function Get-HmwInstance {
    $out = @()
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'hmw-mod.exe'" -ErrorAction SilentlyContinue)) {
        $path = [string]$p.ExecutablePath
        $index = -1
        if ($path -match '(?i)\\Instance(\d+)\\') { $index = [int]$Matches[1] }
        $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if (-not $proc -or $proc.MainWindowHandle -eq [IntPtr]::Zero) { continue }
        $r = New-Object HMWColour.Win+RECT
        [void][HMWColour.Win]::GetWindowRect($proc.MainWindowHandle, [ref]$r)
        $out += [pscustomobject]@{
            # Instance0 on disk is the host, which the user calls player 1.
            Player    = if ($index -ge 0) { $index + 1 } else { -1 }
            Index     = $index
            ProcessId = [int]$p.ProcessId
            Handle    = $proc.MainWindowHandle
            Rect      = New-Object System.Drawing.Rectangle($r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
        }
    }
    $out | Sort-Object Index
}

# One capture of the whole screen, cropped per window, rather than one capture per
# window: all four slices are then from the same instant, so a flash, a muzzle
# flare or a cloud cannot masquerade as a per-instance colour difference.
function Get-ScreenBitmap {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $bmp
}

function Set-WindowForeground([IntPtr]$Handle) {
    for ($i = 0; $i -lt 8; $i++) {
        [void][HMWColour.Win]::ShowWindowAsync($Handle, 9)   # SW_RESTORE
        [void][HMWColour.Win]::SetForegroundWindow($Handle)
        Start-Sleep -Milliseconds 250
        if ([HMWColour.Win]::GetForegroundWindow() -eq $Handle) { Start-Sleep -Milliseconds 350; return $true }
        # Windows resists foreground changes; tapping Alt releases the lock.
        if ($i -eq 2) { [System.Windows.Forms.SendKeys]::SendWait('%'); Start-Sleep -Milliseconds 100 }
    }
    return $false
}

function Invoke-Measure {
    param([string]$Tag = '')

    Initialize-Win32
    $inst = @(Get-HmwInstance)
    if ($inst.Count -eq 0) { Write-Host "  no hmw-mod.exe window found - launch the instances first"; return $null }

    $fg = [HMWColour.Win]::GetForegroundWindow()
    $bmp = Get-ScreenBitmap
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $CaptureRoot ($stamp + $(if ($Tag) { "-$Tag" } else { '' }))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $bmp.Save((Join-Path $dir 'screen.png'), [System.Drawing.Imaging.ImageFormat]::Png)

    $rows = @()
    foreach ($i in $inst) {
        $m = Measure-Region -Bitmap $bmp -Rect $i.Rect
        if (-not $m) { continue }
        $crop = New-Object System.Drawing.Bitmap($i.Rect.Width, $i.Rect.Height)
        $cg = [System.Drawing.Graphics]::FromImage($crop)
        $cg.DrawImage($bmp, (New-Object System.Drawing.Rectangle(0, 0, $i.Rect.Width, $i.Rect.Height)), $i.Rect, [System.Drawing.GraphicsUnit]::Pixel)
        $cg.Dispose()
        $crop.Save((Join-Path $dir ("player$($i.Player).png")), [System.Drawing.Imaging.ImageFormat]::Png)
        $crop.Dispose()

        $rows += [pscustomobject]@{
            Player  = $i.Player
            Pid     = $i.ProcessId
            Focused = ($i.Handle -eq $fg)
            Rect    = "$($i.Rect.X),$($i.Rect.Y) $($i.Rect.Width)x$($i.Rect.Height)"
            R       = $m.R
            G       = $m.G
            B       = $m.B
            Luma    = $m.Luma
            RtoB    = $m.RtoB
            RtoG    = $m.RtoG
        }
    }
    $bmp.Dispose()

    $rows | Format-Table Player, Pid, Focused, Rect, R, G, B, Luma, RtoB, RtoG -AutoSize | Out-String | Write-Host
    Write-Host "  captures: $dir"

    $p1 = $rows | Where-Object { $_.Player -eq 1 }
    $others = @($rows | Where-Object { $_.Player -gt 1 })
    if ($p1 -and $others.Count -ge 2) {
        $avg = ($others | Measure-Object -Property RtoB -Average).Average
        $spread = (($others | Measure-Object -Property RtoB -Maximum).Maximum - ($others | Measure-Object -Property RtoB -Minimum).Minimum)
        $delta = $p1.RtoB - $avg
        Write-Host ("  player 1 R:B {0:N4}   players 2-4 mean {1:N4} (spread {2:N4})   difference {3:N4}" -f $p1.RtoB, $avg, $spread, $delta)
        # The others' spread is the noise floor: two players see different parts of
        # the map, so a difference smaller than that spread is not a finding.
        if ([Math]::Abs($delta) -le $spread) {
            Write-Host "  VERDICT: player 1 is within the spread of the others - no measurable tint difference here"
        } else {
            Write-Host ("  VERDICT: player 1 differs by {0:N0}x the spread among the others" -f ([Math]::Abs($delta) / [Math]::Max($spread, 0.0001)))
        }
    }
    $rows
}

# --- arming and cleanup -----------------------------------------------------

function Get-InstancePath([int]$Index, [string]$Leaf) {
    Join-Path $ContentRoot "Instance$Index\players2\$Leaf"
}

function Backup-InstanceFile([int]$Index, [string]$Leaf) {
    $src = Get-InstancePath $Index $Leaf
    if (-not (Test-Path -LiteralPath $src)) { return $false }
    $dstDir = Join-Path $BackupRoot "Instance$Index"
    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination (Join-Path $dstDir $Leaf) -Force
    return $true
}

function Invoke-Arm {
    Write-Head 'backing up the files that could be changed'
    $count = 0
    foreach ($i in 0..3) {
        foreach ($leaf in @('config_mp.cfg', 'keys_mp.cfg')) {
            if (Backup-InstanceFile $i $leaf) { $count++; Write-Host "  saved Instance$i\$leaf" }
        }
    }
    Write-Host "  $count file(s) in $BackupRoot"

    Write-Head 'arming the candidate binds in the host only'
    $keys = Get-InstancePath 0 'keys_mp.cfg'
    if (-not (Test-Path -LiteralPath $keys)) { throw "host keys_mp.cfg not found at $keys" }

    # Strip any earlier probes first so repeated arming cannot stack duplicates.
    $lines = @(Get-Content -LiteralPath $keys |
        Where-Object { $_ -notmatch [regex]::Escape($ProbeMarker) -and $_ -notmatch $ProbeKeyPattern })
    $lines += $ProbeMarker
    foreach ($k in $Probes.Keys) {
        $lines += ('bind {0} "{1}"' -f $k, $Probes[$k])
    }
    # Built in a variable first: passing a piped -replace result straight to
    # WriteAllLines makes PowerShell read the comma as an argument separator and
    # throw, which is a bug this project has already paid for once.
    [IO.File]::WriteAllLines($keys, $lines)
    foreach ($k in $Probes.Keys) { Write-Host ("  {0} -> {1}" -f $k, $Probes[$k]) }
    Write-Host ""
    Write-Host "  Binds are read at startup, so launch AFTER this. Load Rust, then:"
    Write-Host "    -Measure                 baseline"
    Write-Host "    -Press F5                apply a candidate to player 1"
    Write-Host "    -Measure -Label afterF5  see whether it converged"
}

function Invoke-Cleanup {
    Write-Head 'restoring files from backup'
    if (-not (Test-Path $BackupRoot)) {
        Write-Host "  no backup directory, falling back to stripping probe lines only"
    }
    $restored = 0; $stripped = 0; $rewritten = @()
    foreach ($i in 0..3) {
        foreach ($leaf in @('config_mp.cfg', 'keys_mp.cfg')) {
            $live = Get-InstancePath $i $leaf
            if (-not (Test-Path -LiteralPath $live)) { continue }
            $bak = Join-Path $BackupRoot "Instance$i\$leaf"
            if (Test-Path -LiteralPath $bak) {
                $hLive = (Get-FileHash -LiteralPath $live).Hash
                $hBak  = (Get-FileHash -LiteralPath $bak).Hash
                if ($hLive -ne $hBak) {
                    Copy-Item -LiteralPath $bak -Destination $live -Force
                    $restored++
                    $rewritten += "Instance$i\$leaf"
                }
            } else {
                $lines = @(Get-Content -LiteralPath $live)
                $kept = @($lines | Where-Object { $_ -notmatch [regex]::Escape($ProbeMarker) -and $_ -notmatch $ProbeKeyPattern })
                if ($kept.Count -ne $lines.Count) {
                    [IO.File]::WriteAllLines($live, $kept)
                    $stripped++
                }
            }
        }
    }
    Write-Host "  restored $restored file(s) the game had rewritten: $(if ($rewritten) { $rewritten -join ', ' } else { 'none' })"
    if ($stripped) { Write-Host "  stripped probe binds from $stripped file(s) with no backup" }

    Write-Head 'verifying no probe bind survives anywhere'
    $left = @()
    foreach ($i in 0..3) {
        foreach ($leaf in @('config_mp.cfg', 'keys_mp.cfg')) {
            $live = Get-InstancePath $i $leaf
            if (-not (Test-Path -LiteralPath $live)) { continue }
            $body = Get-Content -LiteralPath $live
            if (($body -match [regex]::Escape($ProbeMarker)) -or ($body -match $ProbeKeyPattern)) {
                $left += "Instance$i\$leaf"
            }
        }
    }
    if ($left) { Write-Host "  STILL PRESENT in: $($left -join ', ')" } else { Write-Host "  clean" }

    Write-Head 'confirming the handler F3 connect bind is intact'
    foreach ($i in 1..3) {
        $keys = Get-InstancePath $i 'keys_mp.cfg'
        if (Test-Path -LiteralPath $keys) {
            $has = Select-String -LiteralPath $keys -Pattern 'bind F3 "connect 127\.0\.0\.1:' -Quiet
            Write-Host "  Instance${i}: F3 connect bind present: $has"
        }
    }

    Write-Head 'deleting captures and backups'
    if (Test-Path $WorkRoot) {
        Remove-Item -LiteralPath $WorkRoot -Recurse -Force
        Write-Host "  removed $WorkRoot"
    } else { Write-Host "  nothing to remove" }
    Write-Host ""
    Write-Host "  Nothing was ever installed into Nucleus. Delete this script to remove the feature entirely."
}

function Invoke-Press {
    param([string]$Key, [int]$Player)

    if (-not $Probes.Contains($Key.ToUpper())) {
        throw "no such candidate '$Key'. Known: $($Probes.Keys -join ', ')"
    }
    Initialize-Win32
    $inst = @(Get-HmwInstance | Where-Object { $_.Player -eq $Player })
    if ($inst.Count -eq 0) { throw "player $Player has no window; found players $((Get-HmwInstance | ForEach-Object { $_.Player }) -join ', ')" }

    $k = $Key.ToUpper()
    Write-Host "  player $Player pid $($inst[0].ProcessId): pressing $k -> $($Probes[$k])"
    # Focus first and abort if it fails. A keystroke sent with the wrong window
    # focused lands in whatever is focused instead, which for a bind key would
    # silently do nothing and for a console would type into the wrong game.
    if (-not (Set-WindowForeground $inst[0].Handle)) { Write-Host "  could not focus the window, nothing sent"; return $false }
    [System.Windows.Forms.SendKeys]::SendWait('{' + $k + '}')
    Start-Sleep -Milliseconds 750
    Write-Host "  sent"
    return $true
}

function Invoke-FocusSweep {
    Write-Head 'focus sweep'
    Write-Host "  Instance 1 is normally the focused window, so before blaming the host role"
    Write-Host "  this checks whether the tint follows focus instead."
    Initialize-Win32
    $inst = @(Get-HmwInstance)
    foreach ($i in $inst) {
        if (-not (Set-WindowForeground $i.Handle)) { Write-Host "  could not focus player $($i.Player), skipping"; continue }
        Start-Sleep -Milliseconds 1200
        Write-Host ""
        Write-Host "  --- focus on player $($i.Player) ---"
        Invoke-Measure -Tag "focus$($i.Player)" | Out-Null
    }
}

# --- self test --------------------------------------------------------------

function Invoke-SelfTest {
    Add-Type -AssemblyName System.Drawing
    # Script-scoped because Assert increments them from its own scope; function-local
    # counters here would be written by $script: and read as zero, which is exactly
    # what the first run of this self test did.
    $script:pass = 0; $script:fail = 0
    function Assert([string]$Name, [scriptblock]$Test) {
        try { $ok = & $Test } catch { $ok = $false; $Name = "$Name (threw: $($_.Exception.Message))" }
        if ($ok) { $script:pass++; Write-Host "  PASS  $Name" } else { $script:fail++; Write-Host "  FAIL  $Name" }
    }

    Write-Head 'measurement maths'

    # A synthetic orange field must read hotter on R:B than a neutral grey one, or
    # the statistic cannot detect the thing it exists to detect.
    $orange = New-Object System.Drawing.Bitmap(200, 200)
    $grey   = New-Object System.Drawing.Bitmap(200, 200)
    for ($y = 0; $y -lt 200; $y++) {
        for ($x = 0; $x -lt 200; $x++) {
            $orange.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(200, 120, 60))
            $grey.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(128, 128, 128))
        }
    }
    $rect = New-Object System.Drawing.Rectangle(0, 0, 200, 200)
    $mo = Measure-Region -Bitmap $orange -Rect $rect
    $mg = Measure-Region -Bitmap $grey   -Rect $rect

    Assert 'orange field reads R:B above 3'        { $mo.RtoB -gt 3.0 }
    Assert 'neutral grey reads R:B of exactly 1'   { [Math]::Abs($mg.RtoB - 1.0) -lt 0.0001 }
    Assert 'orange is warmer than grey'            { $mo.RtoB -gt $mg.RtoB }
    Assert 'channel means are exact on a flat field' { $mo.R -eq 200 -and $mo.G -eq 120 -and $mo.B -eq 60 }
    Assert 'luma of mid grey is mid grey'          { [Math]::Abs($mg.Luma - 128) -lt 0.01 }
    Assert 'centre crop samples fewer than all pixels' { $mo.Samples -lt (200 * 200) -and $mo.Samples -gt 100 }

    # The crop must actually ignore the edges, which is the whole reason the HUD
    # cannot skew the result. A bitmap that is pure red at the border and grey in
    # the middle must measure as grey.
    $framed = New-Object System.Drawing.Bitmap(200, 200)
    for ($y = 0; $y -lt 200; $y++) {
        for ($x = 0; $x -lt 200; $x++) {
            $edge = ($x -lt 40 -or $x -ge 160 -or $y -lt 40 -or $y -ge 160)
            $framed.SetPixel($x, $y, $(if ($edge) { [System.Drawing.Color]::Red } else { [System.Drawing.Color]::FromArgb(128, 128, 128) }))
        }
    }
    $mf = Measure-Region -Bitmap $framed -Rect $rect
    Assert 'a red border does not reach the centre statistic' { [Math]::Abs($mf.RtoB - 1.0) -lt 0.0001 }

    $orange.Dispose(); $grey.Dispose(); $framed.Dispose()

    Write-Head 'candidate definitions'
    Assert 'five candidates plus one control'       { $Probes.Count -eq 6 }
    Assert 'a control probe exists'                 { $Probes.Values -contains 'cg_infobar_fps 0' }
    Assert 'every candidate key is a function key'  { -not ($Probes.Keys | Where-Object { $_ -notmatch '^F([5-9]|1[0-2])$' }) }
    Assert 'no candidate collides with F2 or F3'    { -not ($Probes.Keys | Where-Object { $_ -in @('F2', 'F3') }) }
    Assert 'no candidate command contains a quote'  { -not ($Probes.Values | Where-Object { $_ -match '"' }) }
    Assert 'every dvar probed exists in hmw-mod.exe' {
        # Names verified present by string scan. r_gamma is absent from the binary,
        # so a probe naming it would be testing nothing.
        $known = @('r_filmUseTweaks', 'r_colorScaleUseTweaks', 'r_filmTweakBrightness',
                   'r_filmTweakContrast', 'r_filmTweakDesaturation', 'r_tonemap', 'visionsetnaked',
                   'cg_infobar_fps')
        $used = @()
        foreach ($v in $Probes.Values) {
            foreach ($part in ($v -split ';')) { $used += ($part.Trim() -split '\s+')[0] }
        }
        -not ($used | Where-Object { $_ -notin $known })
    }
    Assert 'no probe names r_gamma, absent from the binary' { -not ($Probes.Values | Where-Object { $_ -match 'r_gamma' }) }

    Write-Head 'arming and stripping are reversible'
    $tmp = Join-Path $env:TEMP ('hmw-colour-selftest-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $f = Join-Path $tmp 'keys_mp.cfg'
        $original = @('unbindall', 'bind W "+forward"', 'bind F3 "connect 127.0.0.1:27016"')
        [IO.File]::WriteAllLines($f, $original)

        function Arm-File([string]$Path) {
            $keep = @(Get-Content -LiteralPath $Path |
                Where-Object { $_ -notmatch [regex]::Escape($ProbeMarker) -and $_ -notmatch $ProbeKeyPattern })
            $keep += $ProbeMarker
            foreach ($k in $Probes.Keys) { $keep += ('bind {0} "{1}"' -f $k, $Probes[$k]) }
            [IO.File]::WriteAllLines($Path, $keep)
        }
        function Strip-File([string]$Path) {
            $keep = @(Get-Content -LiteralPath $Path |
                Where-Object { $_ -notmatch [regex]::Escape($ProbeMarker) -and $_ -notmatch $ProbeKeyPattern })
            [IO.File]::WriteAllLines($Path, $keep)
        }

        Arm-File $f
        Assert 'arming adds a marker line plus one line per candidate' {
            (Get-Content -LiteralPath $f).Count -eq ($original.Count + $Probes.Count + 1)
        }
        Assert 'arming leaves the F3 connect bind untouched' { Select-String -LiteralPath $f -Pattern 'bind F3 "connect 127\.0\.0\.1:27016"' -Quiet }

        # The bind line must look exactly like the proven F3 line: command, key,
        # quoted value, nothing after the closing quote.
        Assert 'no probe bind line carries a trailing comment' {
            $binds = @(Get-Content -LiteralPath $f | Where-Object { $_ -match $ProbeKeyPattern })
            $binds.Count -eq $Probes.Count -and -not ($binds | Where-Object { $_ -notmatch '^bind F\d+ "[^"]+"$' })
        }
        Assert 'the marker sits on its own comment line' {
            $m = @(Get-Content -LiteralPath $f | Where-Object { $_ -match [regex]::Escape($ProbeMarker) })
            $m.Count -eq 1 -and $m[0].TrimStart().StartsWith('//')
        }

        # Arm twice: probes must not stack, or cleanup could leave some behind.
        Arm-File $f
        Assert 'arming twice does not duplicate candidates' {
            (Get-Content -LiteralPath $f).Count -eq ($original.Count + $Probes.Count + 1)
        }

        Strip-File $f
        Assert 'stripping restores the file exactly'  { -not (Compare-Object (Get-Content -LiteralPath $f) $original) }
        Assert 'stripping leaves no marker behind'    { -not (Select-String -LiteralPath $f -Pattern ([regex]::Escape($ProbeMarker)) -Quiet) }

        # Non-vacuity: a stripper keyed on "bind F" would eat the handler's F3 bind
        # and the game's F1/F2 Discord binds. Prove the key restriction is what
        # makes it safe, by showing the naive version does the damage.
        [IO.File]::WriteAllLines($f, @($original + @('bind F1 "discord_accept"', 'bind F2 "discord_deny"')))
        Arm-File $f
        $naive = @(Get-Content -LiteralPath $f | Where-Object { $_ -notmatch '^bind F' })
        Assert 'a naive strip WOULD destroy F3 and the Discord binds' {
            -not ($naive | Where-Object { $_ -match 'connect 127\.0\.0\.1' }) -and
            -not ($naive | Where-Object { $_ -match 'discord_accept' })
        }
        Strip-File $f
        Assert 'the real strip keeps F1, F2 and F3' {
            $body = Get-Content -LiteralPath $f
            ($body -match 'discord_accept') -and ($body -match 'discord_deny') -and ($body -match 'connect 127\.0\.0\.1')
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  $($script:pass) passed, $($script:fail) failed"
    if ($script:fail -gt 0) { exit 1 }
}

# --- entry ------------------------------------------------------------------

if ($SelfTest)   { Invoke-SelfTest; return }
if ($Arm)        { Invoke-Arm; return }
if ($Cleanup)    { Invoke-Cleanup; return }
if ($Press)      { Invoke-Press -Key $Press -Player $Instance | Out-Null; return }
if ($FocusSweep) { Invoke-FocusSweep; return }
if ($Measure)    { Invoke-Measure -Tag $Label | Out-Null; return }

Write-Host "Diagnose-InstanceColour.ps1 - no mode given. One of:"
Write-Host "  -SelfTest -Arm -Measure -FocusSweep -Press <F5..F9> [-Instance N] -Cleanup"
