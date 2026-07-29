#requires -version 5.1
<#
    pdf-to-ae installer.

    Works two ways:

    1. Web (nothing downloaded yet) - the repo is fetched to
       %LOCALAPPDATA%\Programs\pdf-to-ae and installed from there:

           irm https://raw.githubusercontent.com/mickeyperry/pdf-to-ae/main/install.ps1 | iex

    2. Local (you cloned or unzipped the repo) - installs in place:

           powershell -ExecutionPolicy Bypass -File .\install.ps1

    Everything is per-user. No admin rights, nothing written outside HKCU
    and your own profile.
#>
[CmdletBinding()]
param(
    # Where to put the files in web mode.
    [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\pdf-to-ae'),

    # Skip the Poppler check (useful if you installed it some other way).
    [switch] $SkipPoppler
)

$ErrorActionPreference = 'Stop'

$RepoOwner = 'mickeyperry'
$RepoName  = 'pdf-to-ae'
$RepoRef   = 'main'

# ---------------------------------------------------------------- output ----

function Write-Head {
    Write-Host ''
    Write-Host '  pdf-to-ae' -ForegroundColor White
    Write-Host '  Extract PDF pages for After Effects' -ForegroundColor DarkGray
    Write-Host '  -----------------------------------' -ForegroundColor DarkGray
    Write-Host ''
}
function Write-Step { param([string]$T) Write-Host "  $T" -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host "  $T" -ForegroundColor Green }
function Write-Note { param([string]$T) Write-Host "  $T" -ForegroundColor DarkGray }
function Write-Bad  { param([string]$T) Write-Host "  $T" -ForegroundColor Red }

# ---------------------------------------------------------------- poppler ----

function Test-Poppler {
    if (Get-Command 'pdftocairo.exe' -ErrorAction SilentlyContinue) { return $true }
    $pkgRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $pkgRoot) {
        $hit = Get-ChildItem $pkgRoot -Recurse -Filter 'pdftocairo.exe' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $true }
    }
    return $false
}

function Install-Poppler {
    if (Test-Poppler) {
        Write-Ok 'Poppler already installed.'
        return
    }
    Write-Step 'Installing Poppler (the PDF rendering engine)...'

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Bad 'winget was not found, so Poppler cannot be installed automatically.'
        Write-Note 'Install Poppler manually from:'
        Write-Note '  https://github.com/oschwartz10612/poppler-windows/releases'
        Write-Note 'then add its Library\bin folder to PATH and re-run this installer.'
        throw 'Poppler is required.'
    }

    & winget install --id oschwartz10612.Poppler `
        --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null

    if (-not (Test-Poppler)) { throw 'Poppler install did not complete. Try running it by hand: winget install --id oschwartz10612.Poppler' }
    Write-Ok 'Poppler installed.'
}

# ------------------------------------------------------------- get source ----

function Get-LocalRoot {
    # $PSScriptRoot is empty when this script is piped into iex.
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here) -and $MyInvocation.MyCommand.Path) {
        $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if (-not [string]::IsNullOrWhiteSpace($here) -and
        (Test-Path -LiteralPath (Join-Path $here 'src\pdf-to-ae.ps1'))) {
        return $here
    }
    return $null
}

function Get-RepoFromWeb {
    param([string] $Destination)

    Write-Step "Downloading $RepoOwner/$RepoName..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $zipUrl  = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$RepoRef.zip"
    $tmp     = Join-Path ([System.IO.Path]::GetTempPath()) ("pdftoae_" + [Guid]::NewGuid().ToString('N'))
    $zipPath = "$tmp.zip"

    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'pdf-to-ae-installer')
        $wc.DownloadFile($zipUrl, $zipPath)

        [System.IO.Directory]::CreateDirectory($tmp) | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmp -Force

        # The zip contains a single "<repo>-<ref>" folder.
        $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
        if (-not $inner) { throw 'Downloaded archive looked empty.' }

        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
        Move-Item -LiteralPath $inner.FullName -Destination $Destination -Force

        Write-Ok "Installed to $Destination"
        return $Destination
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------- main ----

Write-Head

try {
    $root = Get-LocalRoot
    if ($root) {
        Write-Ok "Using the copy in $root"
    } else {
        $root = Get-RepoFromWeb -Destination $InstallDir
    }

    if (-not $SkipPoppler) { Install-Poppler }

    Write-Step 'Registering the right-click menu...'
    $register = Join-Path $root 'src\install-context-menu.ps1'
    if (-not (Test-Path -LiteralPath $register)) { throw "Missing $register" }
    & $register -ScriptPath (Join-Path $root 'src\pdf-to-ae.ps1') | Out-Null

    Write-Host ''
    Write-Ok 'Done.'
    Write-Host ''
    Write-Note 'Right-click any PDF in Explorer:'
    Write-Note '  Show more options  >  Extract pages for After Effects'
    Write-Note '(Shift+F10 opens that menu directly on Windows 11.)'
    Write-Host ''
    Write-Note 'To remove it later, run Uninstall.cmd in:'
    Write-Note "  $root"
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Bad "Install failed: $($_.Exception.Message)"
    Write-Host ''
    exit 1
}
