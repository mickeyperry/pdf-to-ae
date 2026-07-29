#requires -version 5.1
<#
    pdf-to-ae.ps1
    Rasterize (or split) a PDF into per-page files inside a subfolder next to the PDF,
    named as a zero-padded sequence that After Effects imports as an image sequence.

    Rendering is done by Poppler (pdftocairo / pdfseparate / pdfinfo).

    Examples:
      pdf-to-ae.ps1 -Pdf "C:\art\board.pdf" -Format png  -Dpi 300 -Transparent
      pdf-to-ae.ps1 -Pdf "C:\art\board.pdf" -Format jpeg -Dpi 300
      pdf-to-ae.ps1 -Pdf "C:\art\board.pdf" -Format pdf
      pdf-to-ae.ps1 -Pdf "C:\art\board.pdf" -Prompt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Pdf,

    # png / jpeg = rasterize. pdf = split into single-page vector PDFs.
    [ValidateSet('png', 'jpeg', 'pdf')]
    [string] $Format = 'png',

    [ValidateRange(18, 1200)]
    [int] $Dpi = 300,

    # PNG only: keep the page background transparent instead of filling it white.
    [switch] $Transparent,

    [ValidateRange(1, 100)]
    [int] $JpegQuality = 95,

    # Show a small dialog to pick format / dpi / transparency before running.
    [switch] $Prompt,

    # Keep the console window open when the job succeeds (it always stays open on error).
    [switch] $KeepOpen
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers ----

function Write-Step { param([string] $Text) Write-Host $Text -ForegroundColor Cyan }
function Write-Ok   { param([string] $Text) Write-Host $Text -ForegroundColor Green }
function Write-Warn { param([string] $Text) Write-Host $Text -ForegroundColor Yellow }

function Stop-WithError {
    param([string] $Message)
    Write-Host ''
    Write-Host $Message -ForegroundColor Red
    Write-Host ''
    Write-Host 'Press any key to close...' -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 20 }
    exit 1
}

# Explorer gives this script a console window and takes it away the moment the
# script ends, so an unhandled error is invisible - the window just blinks. This
# trap turns any error we did not anticipate into a message that waits for a key.
trap { Stop-WithError "  Unexpected error: $($_.Exception.Message)" }

# Poppler discovery lives in poppler.ps1 so the installer and this script always
# agree about what counts as an installed Poppler.
$popplerLib = Join-Path $PSScriptRoot 'poppler.ps1'
if (-not (Test-Path -LiteralPath $popplerLib)) {
    Stop-WithError "  Broken install: $popplerLib is missing. Re-run the installer."
}
. $popplerLib

# Start-Process does not quote arguments, so any path containing a space would be
# split into several arguments. Quote anything that needs it.
function ConvertTo-QuotedArg {
    param([string] $Value)
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

# Run a native exe and fail loudly, without PowerShell 5.1's NativeCommandError noise.
function Invoke-Tool {
    param(
        [string]   $Exe,
        [string[]] $Arguments,
        [string]   $What
    )
    $quoted = @($Arguments | ForEach-Object { ConvertTo-QuotedArg $_ })
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $quoted -NoNewWindow -Wait -PassThru `
                           -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if ($p.ExitCode -ne 0) {
            # Poppler dumps its whole usage block on a bad invocation; keep it short.
            $lines = @(Get-Content $stderr -ErrorAction SilentlyContinue |
                       Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^(Copyright|Usage:|\s+-)' })
            $err = if ($lines.Count) { ($lines | Select-Object -First 2) -join '; ' }
                   else { "exit code $($p.ExitCode)" }
            throw "$What failed: $($err.Trim())"
        }
        return (Get-Content $stdout -Raw -ErrorAction SilentlyContinue)
    }
    finally {
        Remove-Item $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Get-PdfPageCount {
    param([string] $Exe, [string] $Path)
    $info = Invoke-Tool -Exe $Exe -Arguments @($Path) -What 'pdfinfo'
    foreach ($line in ($info -split "`r?`n")) {
        if ($line -match '^\s*Pages:\s*(\d+)\s*$') { return [int]$Matches[1] }
    }
    throw 'Could not read the page count. The file may be encrypted or not a valid PDF.'
}

function Format-Size {
    param([long] $Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

# Small options dialog used by the "Custom..." context-menu entry.
function Show-OptionsDialog {
    param([string] $FileName, [string] $DefaultFormat, [int] $DefaultDpi, [bool] $DefaultTransparent)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Extract PDF pages for After Effects'
    $form.ClientSize      = New-Object System.Drawing.Size(400, 250)
    $form.FormBorderStyle = 'FixedDialog'
    $form.StartPosition   = 'CenterScreen'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.TopMost         = $true
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

    $lblFile = New-Object System.Windows.Forms.Label
    $lblFile.Text      = $FileName
    $lblFile.Location  = New-Object System.Drawing.Point(14, 14)
    $lblFile.Size      = New-Object System.Drawing.Size(372, 20)
    $lblFile.AutoEllipsis = $true
    $lblFile.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblFile)

    $lblFmt = New-Object System.Windows.Forms.Label
    $lblFmt.Text     = 'Format'
    $lblFmt.Location = New-Object System.Drawing.Point(14, 50)
    $lblFmt.Size     = New-Object System.Drawing.Size(70, 22)
    $form.Controls.Add($lblFmt)

    $cboFmt = New-Object System.Windows.Forms.ComboBox
    $cboFmt.DropDownStyle = 'DropDownList'
    $cboFmt.Location = New-Object System.Drawing.Point(90, 47)
    $cboFmt.Size     = New-Object System.Drawing.Size(296, 24)
    [void]$cboFmt.Items.AddRange(@(
        'PNG  (lossless raster)',
        'JPEG (smaller, no alpha)',
        'PDF  (vector, one file per page)'
    ))
    switch ($DefaultFormat) {
        'jpeg' { $cboFmt.SelectedIndex = 1 }
        'pdf'  { $cboFmt.SelectedIndex = 2 }
        default { $cboFmt.SelectedIndex = 0 }
    }
    $form.Controls.Add($cboFmt)

    $lblDpi = New-Object System.Windows.Forms.Label
    $lblDpi.Text     = 'Resolution'
    $lblDpi.Location = New-Object System.Drawing.Point(14, 88)
    $lblDpi.Size     = New-Object System.Drawing.Size(70, 22)
    $form.Controls.Add($lblDpi)

    $cboDpi = New-Object System.Windows.Forms.ComboBox
    $cboDpi.DropDownStyle = 'DropDown'
    $cboDpi.Location = New-Object System.Drawing.Point(90, 85)
    $cboDpi.Size     = New-Object System.Drawing.Size(120, 24)
    [void]$cboDpi.Items.AddRange(@('72', '150', '300', '450', '600', '900', '1200'))
    $cboDpi.Text = "$DefaultDpi"
    $form.Controls.Add($cboDpi)

    $lblDpiHint = New-Object System.Windows.Forms.Label
    $lblDpiHint.Text     = 'DPI'
    $lblDpiHint.Location = New-Object System.Drawing.Point(216, 88)
    $lblDpiHint.Size     = New-Object System.Drawing.Size(170, 22)
    $lblDpiHint.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($lblDpiHint)

    $chkTransp = New-Object System.Windows.Forms.CheckBox
    $chkTransp.Text     = 'Transparent background (PNG only)'
    $chkTransp.Location = New-Object System.Drawing.Point(90, 120)
    $chkTransp.Size     = New-Object System.Drawing.Size(296, 24)
    $chkTransp.Checked  = $DefaultTransparent
    $form.Controls.Add($chkTransp)

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Location  = New-Object System.Drawing.Point(90, 148)
    $lblNote.Size      = New-Object System.Drawing.Size(296, 40)
    $lblNote.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($lblNote)

    $sync = {
        $isPdf = ($cboFmt.SelectedIndex -eq 2)
        $isPng = ($cboFmt.SelectedIndex -eq 0)
        $cboDpi.Enabled    = -not $isPdf
        $lblDpi.Enabled    = -not $isPdf
        $chkTransp.Enabled = $isPng
        if ($isPdf) {
            $lblNote.Text = 'Vector pages stay infinitely scalable in AE (turn on Continuous Rasterize).'
        } elseif ($isPng) {
            $lblNote.Text = 'Best all-round choice for AE artwork.'
        } else {
            $lblNote.Text = 'Backgrounds are flattened to white.'
        }
    }
    $cboFmt.Add_SelectedIndexChanged($sync)
    & $sync

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'Extract'
    $btnOk.Location = New-Object System.Drawing.Point(206, 202)
    $btnOk.Size     = New-Object System.Drawing.Size(88, 30)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk)
    $form.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(298, 202)
    $btnCancel.Size     = New-Object System.Drawing.Size(88, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $dpiValue = 0
    if (-not [int]::TryParse($cboDpi.Text.Trim(), [ref]$dpiValue)) { $dpiValue = $DefaultDpi }
    if ($dpiValue -lt 18)   { $dpiValue = 18 }
    if ($dpiValue -gt 1200) { $dpiValue = 1200 }

    $fmt = @('png', 'jpeg', 'pdf')[$cboFmt.SelectedIndex]
    return [pscustomobject]@{
        Format      = $fmt
        Dpi         = $dpiValue
        Transparent = ($chkTransp.Checked -and $fmt -eq 'png')
    }
}

# ------------------------------------------------------------------- main ----

try {
    $Host.UI.RawUI.WindowTitle = 'PDF -> After Effects'
} catch { }

Write-Host ''
Write-Host '  PDF -> After Effects' -ForegroundColor White
Write-Host '  --------------------' -ForegroundColor DarkGray

# --- validate input ---
if (-not (Test-Path -LiteralPath $Pdf -PathType Leaf)) {
    Stop-WithError "File not found: $Pdf"
}
$pdfItem = Get-Item -LiteralPath $Pdf
if ($pdfItem.Extension -notmatch '^\.pdf$') {
    Stop-WithError "Not a PDF file: $($pdfItem.Name)"
}

# --- locate poppler ---
$bin = Resolve-PopplerBin
if (-not $bin) {
    Stop-WithError @"
  Poppler (the PDF rendering engine) was not found.

  Re-run the installer to fetch it:
      irm https://raw.githubusercontent.com/mickeyperry/pdf-to-ae/main/install.ps1 | iex

  Or install it yourself:
      winget install --id oschwartz10612.Poppler
"@
}
$pdftocairo   = Join-Path $bin 'pdftocairo.exe'
$pdfseparate  = Join-Path $bin 'pdfseparate.exe'
$pdfinfo      = Join-Path $bin 'pdfinfo.exe'

# --- optional dialog ---
if ($Prompt) {
    $choice = Show-OptionsDialog -FileName $pdfItem.Name -DefaultFormat $Format `
                                 -DefaultDpi $Dpi -DefaultTransparent $Transparent.IsPresent
    if (-not $choice) { Write-Warn '  Cancelled.'; exit 0 }
    $Format      = $choice.Format
    $Dpi         = $choice.Dpi
    $Transparent = [switch]$choice.Transparent
}
if ($Format -ne 'png') { $Transparent = [switch]$false }

# --- page count ---
Write-Host ''
Write-Host "  Source : $($pdfItem.Name)"
try {
    $pageCount = Get-PdfPageCount -Exe $pdfinfo -Path $pdfItem.FullName
} catch {
    Stop-WithError "  $($_.Exception.Message)"
}
if ($pageCount -lt 1) { Stop-WithError '  This PDF reports zero pages.' }

# --- output folder: <pdf folder>\<pdf name>_<tag>\ ---
switch ($Format) {
    'pdf'  { $tag = 'pdfpages' }
    'jpeg' { $tag = "jpg$Dpi" }
    default {
        $tag = "png$Dpi"
        if (-not $Transparent) { $tag += '_opaque' }
    }
}
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($pdfItem.Name)
# Drop characters that are legal in a file name but awkward in a sequence name
# (PowerShell wildcards, shell metacharacters), then tidy the leftover spacing.
$safeBase = $baseName -replace '[\[\]#%&{}<>*?$!:@+`|=]', ' '
$safeBase = ($safeBase -replace '\s+', ' ').Trim(' ', '_', '.', '-')
if ([string]::IsNullOrWhiteSpace($safeBase)) { $safeBase = 'page' }

$outDir = Join-Path $pdfItem.DirectoryName "$safeBase`_$tag"
# Not New-Item -Path: that treats [ ] in the parent folder name as wildcards.
$null = [System.IO.Directory]::CreateDirectory($outDir)

$label = if ($Format -eq 'pdf') { 'single-page PDF' } else { "$($Format.ToUpper()) at $Dpi DPI" }
if ($Transparent) { $label += ', transparent' }
Write-Host "  Pages  : $pageCount"
Write-Host "  Output : $label"
Write-Host "  Folder : $outDir"
Write-Host ''

# --- render, one page at a time so progress is real and names are exact ---
$pad     = 4
$ext     = @{ png = 'png'; jpeg = 'jpg'; pdf = 'pdf' }[$Format]
$written = New-Object System.Collections.Generic.List[string]
$failed  = New-Object System.Collections.Generic.List[string]

for ($page = 1; $page -le $pageCount; $page++) {
    $stem    = '{0}_{1}' -f $safeBase, $page.ToString().PadLeft($pad, '0')
    $target  = Join-Path $outDir "$stem.$ext"
    $percent = [int](($page - 1) / $pageCount * 100)

    Write-Progress -Activity "Extracting $($pdfItem.Name)" `
                   -Status "Page $page of $pageCount" -PercentComplete $percent

    try {
        if ($Format -eq 'pdf') {
            # Extracting exactly one page lets us pass a literal destination name,
            # so no %d pattern and no post-rename pass are needed.
            $toolArgs = @('-f', "$page", '-l', "$page", $pdfItem.FullName, $target)
            $null = Invoke-Tool -Exe $pdfseparate -Arguments $toolArgs -What "page $page"
        }
        else {
            # -singlefile makes pdftocairo append the extension only, no page digits.
            $toolArgs = @('-r', "$Dpi", '-f', "$page", '-l', "$page", '-singlefile')
            if ($Format -eq 'png') {
                $toolArgs += '-png'
                if ($Transparent) { $toolArgs += '-transp' }
            } else {
                $toolArgs += @('-jpeg', '-jpegopt', "quality=$JpegQuality,optimize=y")
            }
            $toolArgs += @($pdfItem.FullName, (Join-Path $outDir $stem))
            $null = Invoke-Tool -Exe $pdftocairo -Arguments $toolArgs -What "page $page"
        }

        if (Test-Path -LiteralPath $target) {
            $written.Add($target)
        } else {
            $failed.Add("page $page (no output file)")
        }
    }
    catch {
        $failed.Add("page $page ($($_.Exception.Message))")
    }
}
Write-Progress -Activity 'Extracting' -Completed

# --- report ---
if ($written.Count -eq 0) {
    Stop-WithError "  Nothing was written. $(if ($failed.Count) { $failed[0] })"
}

$totalBytes = ($written | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum
$first      = Split-Path -Leaf $written[0]

Write-Ok "  Done. $($written.Count) of $pageCount page(s) -> $(Format-Size $totalBytes)"
Write-Host "  First file: $first" -ForegroundColor DarkGray

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Warn "  $($failed.Count) page(s) failed:"
    $failed | Select-Object -First 5 | ForEach-Object { Write-Warn "    - $_" }
}

Write-Host ''
if ($Format -eq 'pdf') {
    Write-Host '  In AE: import the pages, then switch on Continuous Rasterize' -ForegroundColor DarkGray
    Write-Host '  (the sun icon) to keep them sharp at any scale.' -ForegroundColor DarkGray
} else {
    Write-Host '  In AE: File > Import > File, pick the first frame and tick' -ForegroundColor DarkGray
    Write-Host "  `"$($ext.ToUpper()) Sequence`" to bring all pages in as one layer." -ForegroundColor DarkGray
}
Write-Host ''

if ($failed.Count -gt 0 -or $KeepOpen) {
    Write-Host '  Press any key to close...' -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 15 }
} else {
    Start-Sleep -Milliseconds 1400
}
exit 0
