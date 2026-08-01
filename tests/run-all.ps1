# Runs every test suite in the repo. Touches nothing outside a temp sandbox.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$failed = 0

# Do not name the parameter $Args: it collides with the automatic variable and
# the splat silently expands to nothing, which ran the watcher instead of its
# self test and reported a pass on no output.
function Invoke-Suite([string]$Name, [string]$Path, [string[]]$ScriptArgs) {
    ""
    "=== $Name ==="
    if ($ScriptArgs) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @ScriptArgs
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path
    }
    if ($LASTEXITCODE -ne 0) {
        "  -> SUITE FAILED"
        $script:failed++
    }
}

Invoke-Suite 'handler helpers under Jint' (Join-Path $PSScriptRoot 'dryrun-helpers.ps1') @()
Invoke-Suite 'F2 watcher guest selection'  (Join-Path $repo 'HorizonMW\HMWConnectHotkey.ps1') @('-SelfTest')

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
if ($failed -gt 0) { "$failed suite(s) failed"; exit 1 }
'ALL SUITES PASSED'
exit 0
