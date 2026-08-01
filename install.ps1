<#
.SYNOPSIS
    Installs the handler into a Nucleus Co-op install and verifies every file landed.

.DESCRIPTION
    Nucleus loads handlers only from '<NucleusRoot>\handlers\<Name>.js'. It does not
    scan subfolders. The same-named folder next to that file is what
    Context.ScriptFolder resolves to at runtime, and it holds the graphics presets,
    the F2 watcher and the watcher's launcher.

    This script exists because copying HorizonMW.js into the asset folder instead of
    the handlers root looks correct, verifies clean against its own target, and has no
    effect whatsoever. A frame cap dropdown installed that way never appeared in
    Nucleus, because an older copy at the root kept being loaded, and the two files
    were a single commit apart so nothing about the running handler looked stale.

    Verifying by hash against the intended destination is what catches that class of
    mistake, so every copy here is confirmed afterwards rather than assumed.
#>
[CmdletBinding()]
param(
    [string]$NucleusRoot = 'C:\NucleusCoop'
)

$ErrorActionPreference = 'Stop'

$repo     = Split-Path -Parent $MyInvocation.MyCommand.Path
$handlers = Join-Path $NucleusRoot 'handlers'
$assetDir = Join-Path $handlers 'HorizonMW'

if (-not (Test-Path -LiteralPath $handlers)) {
    Write-Error "no handlers folder at $handlers - is -NucleusRoot right?"
    exit 1
}

# The handler script goes to the root. Everything under HorizonMW\ is an asset and
# goes to the asset folder, preserving subfolders such as Graphics.
$plan = @(
    [pscustomobject]@{ From = Join-Path $repo 'HorizonMW.js'; To = Join-Path $handlers 'HorizonMW.js' }
)
foreach ($f in Get-ChildItem (Join-Path $repo 'HorizonMW') -Recurse -File) {
    $rel = $f.FullName.Substring((Join-Path $repo 'HorizonMW').Length).TrimStart('\')
    $plan += [pscustomobject]@{ From = $f.FullName; To = Join-Path $assetDir $rel }
}

$failed = 0
foreach ($item in $plan) {
    $dir = Split-Path -Parent $item.To
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $item.From -Destination $item.To -Force

    $src = (Get-FileHash -LiteralPath $item.From).Hash
    $dst = (Get-FileHash -LiteralPath $item.To).Hash
    $rel = $item.To.Substring($handlers.Length).TrimStart('\')
    if ($src -eq $dst) {
        "  ok      $rel"
    } else {
        "  MISMATCH $rel"
        $failed++
    }
}

# A copy of the handler inside the asset folder is inert, but it is exactly what
# made the last misinstall invisible, so say so every time.
$stray = Join-Path $assetDir 'HorizonMW.js'
if (Test-Path -LiteralPath $stray) {
    ""
    "  note: a copy of the handler exists at handlers\HorizonMW\HorizonMW.js."
    "        Nucleus does not load it. Deleting it removes a source of confusion."
}

# Handlers are parsed when Nucleus starts, so a running instance is still serving
# the previous version no matter what this script just wrote.
if (@(Get-Process NucleusCoop -ErrorAction SilentlyContinue).Count -gt 0) {
    ""
    "  note: NucleusCoop is running and parsed its handlers at startup."
    "        Restart it before expecting these changes, including new dropdowns."
}

""
if ($failed -gt 0) { "$failed file(s) failed to verify"; exit 1 }
"installed $($plan.Count) file(s) to $handlers"
exit 0
