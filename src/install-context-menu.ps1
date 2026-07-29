#requires -version 5.1
<#
    install-context-menu.ps1

    Adds an "Extract pages for After Effects" cascading submenu to the right-click
    menu of every .pdf file, for the current user only (no admin rights needed).

    Registry layout:
      HKCU:\Software\Classes\SystemFileAssociations\.pdf\shell\PdfToAE
          MUIVerb                  the parent entry caption
          ExtendedSubCommandsKey   -> PdfToAE.Menu  (relative to Software\Classes)
      HKCU:\Software\Classes\PdfToAE.Menu\shell\<NN...>\command
          one entry per preset

    Re-running this script is safe; it rewrites the keys in place.
#>
[CmdletBinding()]
param(
    # Where pdf-to-ae.ps1 lives. Defaults to this script's own folder.
    [string] $ScriptPath
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated inside a param() default, so resolve it here.
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) {
        $here = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }
    $ScriptPath = Join-Path $here 'pdf-to-ae.ps1'
}

$VerbKey = 'HKCU:\Software\Classes\SystemFileAssociations\.pdf\shell\PdfToAE'
$MenuId  = 'PdfToAE.Menu'
$MenuKey = "HKCU:\Software\Classes\$MenuId"

# ---------------------------------------------------------------- checks ----

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Worker script not found: $ScriptPath"
}
# .ProviderPath, not .Path: for a UNC or mapped location .Path comes back
# provider-qualified ("Microsoft.PowerShell.Core\FileSystem::\\host\share\..."),
# and powershell.exe -File cannot open that - the console window opened by
# Explorer would close instantly with no message.
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath

if ($ScriptPath -notmatch '^([A-Za-z]:\\|\\\\)') {
    throw "Refusing to register a path Explorer cannot launch: $ScriptPath"
}

# Pick an icon for the menu: After Effects if it is installed, else a generic one.
# ProgramW6432 is checked first because a 32-bit PowerShell reports the x86 folder
# in ProgramFiles, where After Effects is not.
$icon = "$env:SystemRoot\System32\imageres.dll,-68"
$adobeRoots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
              Where-Object { $_ } | Select-Object -Unique |
              ForEach-Object { Join-Path $_ 'Adobe' }
$aeCandidates = Get-ChildItem -Path $adobeRoots -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'Adobe After Effects*' } |
                Sort-Object Name -Descending
foreach ($dir in $aeCandidates) {
    $exe = Join-Path $dir.FullName 'Support Files\AfterFX.exe'
    if (Test-Path -LiteralPath $exe) { $icon = "$exe,0"; break }
}

# Explorer runs this command as a 64-bit process, so the literal System32 path is
# the right one to write. Fall back to the bare name if that copy is missing.
$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

function New-Command {
    param([string] $Tail)
    # %1 is the full path of the right-clicked PDF. -File (not -Command) is
    # deliberate: Windows hands "%1" through as a single argument whatever it
    # contains, so apostrophes and $ in a file name stay literal.
    return "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Pdf `"%1`" $Tail"
}

# ----------------------------------------------------------- menu entries ----
# Order is controlled by the key name, which Explorer sorts alphabetically.

$entries = @(
    @{ Key = '10_png300';  Label = 'PNG sequence  -  300 DPI, transparent';   Tail = '-Format png -Dpi 300 -Transparent' }
    @{ Key = '20_png600';  Label = 'PNG sequence  -  600 DPI, transparent';   Tail = '-Format png -Dpi 600 -Transparent' }
    @{ Key = '30_png300w'; Label = 'PNG sequence  -  300 DPI, white backing'; Tail = '-Format png -Dpi 300' }
    @{ Key = '40_jpg300';  Label = 'JPEG sequence -  300 DPI';                Tail = '-Format jpeg -Dpi 300' }
    @{ Key = '50_vector';  Label = 'Vector pages  -  one PDF per page';       Tail = '-Format pdf'; Separator = $true }
    @{ Key = '60_custom';  Label = 'Custom...';                               Tail = '-Prompt';     Separator = $true }
)

# ---------------------------------------------------------------- install ----

Write-Host ''
Write-Host '  Installing PDF -> After Effects context menu' -ForegroundColor White
Write-Host '  -------------------------------------------' -ForegroundColor DarkGray
Write-Host "  Worker : $ScriptPath"
Write-Host "  Icon   : $($icon -replace ',.*$','')"
Write-Host ''

# Clear any previous install so removed presets do not linger.
Remove-Item -LiteralPath $VerbKey -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $MenuKey -Recurse -Force -ErrorAction SilentlyContinue

# Parent entry. It must have no "command" subkey, or the submenu is ignored.
$null = New-Item -Path $VerbKey -Force
New-ItemProperty -Path $VerbKey -Name 'MUIVerb' -Value 'Extract pages for After Effects' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $VerbKey -Name 'Icon'    -Value $icon                             -PropertyType String -Force | Out-Null
New-ItemProperty -Path $VerbKey -Name 'ExtendedSubCommandsKey' -Value "$MenuId"           -PropertyType String -Force | Out-Null

# Submenu items.
$null = New-Item -Path (Join-Path $MenuKey 'shell') -Force
foreach ($e in $entries) {
    $itemKey = Join-Path (Join-Path $MenuKey 'shell') $e.Key
    $null = New-Item -Path $itemKey -Force
    New-ItemProperty -Path $itemKey -Name 'MUIVerb' -Value $e.Label -PropertyType String -Force | Out-Null

    if ($e.Separator) {
        # 0x20 = ECF_SEPARATORBEFORE, draws a divider above the entry.
        New-ItemProperty -Path $itemKey -Name 'CommandFlags' -Value 0x20 -PropertyType DWord -Force | Out-Null
    }

    $cmdKey = Join-Path $itemKey 'command'
    $null = New-Item -Path $cmdKey -Force
    Set-ItemProperty -Path $cmdKey -Name '(Default)' -Value (New-Command $e.Tail)

    Write-Host "  + $($e.Label)" -ForegroundColor Green
}

Write-Host ''
Write-Host '  Installed for the current user.' -ForegroundColor Green
Write-Host ''
Write-Host '  On Windows 11 the entry lives under "Show more options"' -ForegroundColor DarkGray
Write-Host '  in the right-click menu (or press Shift+F10).' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  To remove it later, run uninstall-context-menu.ps1' -ForegroundColor DarkGray
Write-Host ''
