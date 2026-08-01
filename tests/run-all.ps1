# Runs every test suite in the repo. Touches nothing outside a temp sandbox.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$failed = 0

# Do not name the parameter $Args: it collides with the automatic variable and
# the splat silently expands to nothing, which ran the watcher instead of its
# self test and reported a pass on no output.
function Invoke-Suite([string]$Name, [string]$Path, [string[]]$ScriptArgs, [string]$Host64Or32 = '64') {
    ""
    "=== $Name ==="
    # NucleusCoop.exe is x86, so the watcher it launches is redirected to
    # SysWOW64 and runs with a 4-byte IntPtr. Numeric conversions that succeed
    # in a 64-bit shell can overflow there, so the watcher's suite has to run at
    # both widths. Testing only at 64 bits hid the lParam bug completely.
    $exe = if ($Host64Or32 -eq '32') {
        Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    } else {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    if (-not (Test-Path -LiteralPath $exe)) {
        "  -> SKIPPED, no $Host64Or32-bit PowerShell at $exe"
        return
    }
    if ($ScriptArgs) {
        & $exe -NoProfile -ExecutionPolicy Bypass -File $Path @ScriptArgs
    } else {
        & $exe -NoProfile -ExecutionPolicy Bypass -File $Path
    }
    if ($LASTEXITCODE -ne 0) {
        "  -> SUITE FAILED"
        $script:failed++
    }
}

Invoke-Suite 'handler helpers under Jint' (Join-Path $PSScriptRoot 'dryrun-helpers.ps1') @()
$watcher = Join-Path $repo 'HorizonMW\HMWConnectHotkey.ps1'
Invoke-Suite 'F2 watcher self test, 64-bit host' $watcher @('-SelfTest') '64'
Invoke-Suite 'F2 watcher self test, 32-bit host (as Nucleus runs it)' $watcher @('-SelfTest') '32'

""
"=== syntax ==="
$errors = $null; $tokens = $null
foreach ($ps1 in Get-ChildItem $repo -Recurse -Filter *.ps1) {
    [void][System.Management.Automation.Language.Parser]::ParseFile($ps1.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        "  FAIL  $($ps1.Name): $($errors[0].Message)"
        $failed++
    } else {
        "  PASS  $($ps1.Name) parses"
    }
}

$jint = 'C:\NucleusCoop\Jint.dll'
if (Test-Path $jint) {
    Add-Type -Path $jint
    try {
        $parser = New-Object Jint.Parser.JavaScriptParser
        [void]$parser.Parse([IO.File]::ReadAllText((Join-Path $repo 'HorizonMW.js')))
        '  PASS  HorizonMW.js parses under Nucleus'' own Jint'
    } catch {
        "  FAIL  HorizonMW.js: $($_.Exception.Message)"
        $failed++
    }
} else {
    '  SKIP  Jint.dll not found, cannot syntax check HorizonMW.js'
}

""
"=== per-instance isolation of shared writable game files ==="
# Everything under main\ is symlinked, so any file the game writes there is one
# physical file shared by every instance unless it is listed for hardcopy. These
# were found by diffing the install after a session; losing an entry would
# silently reintroduce cross-instance interference.
$js = [IO.File]::ReadAllText((Join-Path $repo 'HorizonMW.js'))
$copyBlock = [regex]::Match($js, 'Game\.FileSymlinkCopyInstead\s*=\s*\[(.*?)\];', 'Singleline')
$exclBlock = [regex]::Match($js, 'Game\.FileSymlinkExclusions\s*=\s*\[(.*?)\];', 'Singleline')
function Listed([System.Text.RegularExpressions.Match]$m, [string]$name) {
    if (-not $m.Success) { return $false }
    # Strip // comments so a filename merely mentioned in prose does not count.
    $body = ($m.Groups[1].Value -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    return [bool]([regex]::IsMatch($body, '"' + [regex]::Escape($name) + '"'))
}
foreach ($f in @('toc0.dcache','toc1.dcache','data0.dcache','data1.dcache','cmr_history','imgui.ini','games_mp.log')) {
    if (Listed $copyBlock $f) { "  PASS  $f is hardcopied per instance" }
    else { "  FAIL  $f would be symlinked and shared by every instance"; $failed++ }
    if (Listed $exclBlock $f) { "  FAIL  $f is also excluded, so no instance would get it"; $failed++ }
}
# Non-vacuity: a name that is only mentioned in a comment must not count as listed.
if (Listed $copyBlock 'definitely-not-a-real-file.dcache') { "  FAIL  the listing check matches anything"; $failed++ }
else { "  PASS  listing check rejects a name that is not in the array" }

""
if ($failed -gt 0) { "$failed suite(s) failed"; exit 1 }
'ALL SUITES PASSED'
exit 0
