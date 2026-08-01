<#
.SYNOPSIS
Builds a HorizonMW graphics preset from an instance's real in-game settings.

.DESCRIPTION
The shipped presets only touch dvars whose type and direction are unambiguous,
because HMW has several string-enum graphics dvars whose accepted values are not
documented, and a rejected value is silently ignored rather than reported.

This captures a preset that is guaranteed valid, because every value comes from
the game itself:

  1. Launch through Nucleus with the Graphics option set to Default.
  2. In one instance, set the graphics you want and apply them.
  3. Quit that instance, so HMW flushes config_mp.cfg to disk.
  4. Run this script, naming the preset.

Only graphics dvars are captured. Window, identity and input dvars are excluded,
both because they are per-instance and because the handler refuses to apply them
from a preset anyway.

.EXAMPLE
.\Capture-GraphicsPreset.ps1 -Name Low -Instance 1

.EXAMPLE
.\Capture-GraphicsPreset.ps1 -Name Extra -FromInstall
#>
[CmdletBinding(DefaultParameterSetName = 'Instance')]
param(
    # Preset name. Use one of the names in the Nucleus dropdown to replace it.
    [Parameter(Mandatory)]
    [string]$Name,

    # Which Nucleus instance to read, zero based, matching the Instance<N> folders.
    [Parameter(ParameterSetName = 'Instance')]
    [int]$Instance = 0,

    # Read the untouched Steam install config instead of a Nucleus instance.
    [Parameter(ParameterSetName = 'Install')]
    [switch]$FromInstall,

    [string]$ContentRoot = 'C:\NucleusCoop\content\HorizonMW',

    [string]$InstallRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Call of Duty Modern Warfare Remastered',

    # Where to write. Defaults to the Graphics folder beside this script.
    [string]$PresetDir = (Join-Path $PSScriptRoot 'Graphics'),

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Graphics dvars worth capturing. Prefixes are matched whole-word against the
# dvar name, so r_picmip does not also pull in unrelated dvars.
$Include = @(
    'r_picmip', 'r_picmip_bump', 'r_picmip_spec', 'r_picmip_water',
    'r_texFilterAnisoMin', 'r_texFilterAnisoMax',
    'r_dof_limit', 'r_mbLimit', 'r_ssaoLimit', 'r_mdaoLimit', 'r_sssLimit',
    'r_dlightForceLimit', 'r_postAA', 'r_ssaaSamples', 'r_depthPrepass',
    'r_lodScaleRigid', 'r_lodScaleSkinned', 'r_drawWater', 'r_glow_allowed',
    'r_videoMemoryScale', 'r_vsync',
    'r_renderResolution', 'r_renderResolutionNative',
    'sm_enable', 'sm_maxLightsWithShadows', 'sm_tileResolution',
    'sm_cacheSpotShadows', 'sm_cacheSunShadow', 'sm_sunShadowScaleLocked',
    'fx_marks', 'ai_corpseLimit', 'ragdoll_enable', 'ragdoll_mp_limit',
    'snd_lowQualityAudio'
)

# Refused by the handler even if present, so never write them into a preset.
$Blocked = @('r_fullscreen', 'r_fullscreenWindow', 'r_mode', 'vid_xpos', 'vid_ypos', 'name')

if ($FromInstall) {
    $cfg = Join-Path $InstallRoot 'players2\config_mp.cfg'
    $source = 'the untouched Steam install'
} else {
    $cfg = Join-Path $ContentRoot "Instance$Instance\players2\config_mp.cfg"
    $source = "Nucleus Instance$Instance"
}

if (-not (Test-Path -LiteralPath $cfg)) {
    throw "No config at $cfg. Launch once through Nucleus first, or pass -FromInstall."
}

# HMW only flushes config_mp.cfg on exit, so a config still held open by a
# running instance does not yet contain what was just changed in the menu.
$running = @(Get-Process -Name 'hmw-mod' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Warning "$($running.Count) hmw-mod.exe still running. HMW writes config_mp.cfg on exit, so quit the instance first or the capture will miss the settings you just changed."
}

$captured = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $cfg) {
    $m = [regex]::Match($line.Trim(), '^seta\s+(\S+)\s+"(.*)"\s*$')
    if (-not $m.Success) { continue }
    $dvar = $m.Groups[1].Value
    if ($Blocked -contains $dvar) { continue }
    if ($Include -notcontains $dvar) { continue }
    $captured[$dvar] = $m.Groups[2].Value
}

if ($captured.Count -eq 0) {
    throw "Found no graphics dvars in $cfg. Is that really an HMW config?"
}

if (-not (Test-Path -LiteralPath $PresetDir)) {
    New-Item -ItemType Directory -Path $PresetDir -Force | Out-Null
}
$out = Join-Path $PresetDir "$Name.cfg"
if ((Test-Path -LiteralPath $out) -and -not $Force) {
    throw "$out already exists. Pass -Force to overwrite it."
}

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$body = New-Object System.Collections.Generic.List[string]
$body.Add("// HorizonMW graphics preset: $Name")
$body.Add("// Captured from $source on $stamp.")
$body.Add('// Every value below came from the game itself, so all of them are accepted.')
$body.Add('')
foreach ($dvar in $captured.Keys) {
    $body.Add("seta $dvar `"$($captured[$dvar])`"")
}

Set-Content -LiteralPath $out -Value $body -Encoding Ascii

Write-Host "Captured $($captured.Count) dvar(s) from $source" -ForegroundColor Green
Write-Host "  -> $out"
if ($Name -notin @('Low', 'Medium', 'High', 'Extra')) {
    Write-Warning "'$Name' is not one of the names in the Nucleus dropdown (Low, Medium, High, Extra), so it will not be selectable until HMW_GRAPHICS_PRESETS in HorizonMW.js lists it too."
}
Write-Host ''
Write-Host 'Copy it to the installed handler to use it:' -ForegroundColor Cyan
Write-Host "  Copy-Item '$out' 'C:\NucleusCoop\handlers\HorizonMW\Graphics\' -Force"
