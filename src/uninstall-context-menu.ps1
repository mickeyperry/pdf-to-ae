#requires -version 5.1
<#
    uninstall-context-menu.ps1
    Removes the "Extract pages for After Effects" PDF context menu for this user.
    Leaves Poppler and the scripts on disk.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$keys = @(
    'HKCU:\Software\Classes\SystemFileAssociations\.pdf\shell\PdfToAE',
    'HKCU:\Software\Classes\PdfToAE.Menu'
)

Write-Host ''
foreach ($k in $keys) {
    if (Test-Path -LiteralPath $k) {
        Remove-Item -LiteralPath $k -Recurse -Force
        Write-Host "  removed  $k" -ForegroundColor Yellow
    } else {
        Write-Host "  absent   $k" -ForegroundColor DarkGray
    }
}
Write-Host ''
Write-Host '  Context menu removed.' -ForegroundColor Green
Write-Host ''
