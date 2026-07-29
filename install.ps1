#requires -version 5.1
<#
    pdf-to-ae installer.

    Works two ways:

    1. Web (nothing downloaded yet) - the repo is fetched to
       %LOCALAPPDATA%\Programs\pdf-to-ae and installed from there:

           irm https://raw.githubusercontent.com/mickeyperry/pdf-to-ae/main/install.ps1 | iex

    2. Local (you cloned or unzipped the repo) - the files are copied to that
       same folder and installed from there, so the menu keeps working after you
       delete the download. Add -InPlace to register the copy you are sitting in:

           powershell -ExecutionPolicy Bypass -File .\install.ps1

    Everything is per-user. No admin rights, nothing written outside HKCU
    and your own profile.
#>
[CmdletBinding()]
param(
    # Where to put the files in web mode.
    [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\pdf-to-ae'),

    # Skip the Poppler check (useful if you installed it some other way).
    [switch] $SkipPoppler,

    # Register the scripts where they already sit instead of copying them to
    # $InstallDir. For working on a clone - see Copy-RepoLocal for why the copy
    # is the default.
    [switch] $InPlace
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

function Install-Poppler {
    param([string] $SourceRoot)

    # One shared search list for installer and worker, so they can never disagree
    # about whether this machine already has a usable Poppler.
    . (Join-Path $SourceRoot 'src\poppler.ps1')

    $bin = Resolve-PopplerBin
    if ($bin) {
        Write-Ok "Poppler already installed."
        Write-Note "  $bin"
        return
    }

    Write-Step 'Installing Poppler (the PDF rendering engine)...'

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $bin = Install-PopplerViaWinget
        if ($bin) {
            Write-Ok 'Poppler installed via winget.'
            return
        }
        Write-Note 'winget did not produce a working Poppler; downloading it directly instead.'
    } else {
        Write-Note 'No winget on this machine; downloading Poppler directly instead.'
    }

    # Works on LTSC, Server and un-updated Windows 10, where winget is absent.
    try {
        $bin = Install-PopplerFromGitHub
    } catch {
        Write-Bad "Could not download Poppler: $($_.Exception.Message)"
        Write-Note 'Install it by hand from:'
        Write-Note '  https://github.com/oschwartz10612/poppler-windows/releases'
        Write-Note 'then add its Library\bin folder to PATH and re-run this installer.'
        throw 'Poppler is required.'
    }

    if (-not $bin) { throw 'Poppler was downloaded but no usable bin folder was found inside it.' }
    Write-Ok 'Poppler downloaded.'
    Write-Note "  $bin"
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

function Test-SamePath {
    param([string] $A, [string] $B)
    if (-not $A -or -not $B) { return $false }
    $norm = { param($p) $p.TrimEnd('\', '/').ToLowerInvariant() }
    return ((& $norm $A) -eq (& $norm $B))
}

# Empty the install folder but keep a Poppler we downloaded into it - that copy is
# 50-odd MB and re-fetching it on every re-install would be rude.
function Clear-InstallDir {
    param([string] $Destination)

    if (-not (Test-Path -LiteralPath $Destination)) {
        [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
        return
    }
    Get-ChildItem -LiteralPath $Destination -Force |
        Where-Object { $_.Name -ne 'poppler' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
}

# Populate the install folder from a folder of files, keeping any Poppler already
# there. The registry stores an absolute path to the worker, so registering it
# where it was unzipped (Downloads, a USB stick, a network share) means the menu
# breaks silently the day that folder moves. Installing from a fixed location
# under LOCALAPPDATA removes that whole class of failure.
function Copy-RepoInto {
    param([string] $Source, [string] $Destination)

    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
    Clear-InstallDir -Destination $Destination

    Get-ChildItem -LiteralPath $Source -Force |
        Where-Object { $_.Name -notin @('.git', '.github', 'poppler') } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
        }

    Write-Ok "Installed to $Destination"
    return $Destination
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

        return (Copy-RepoInto -Source $inner.FullName -Destination $Destination)
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------- main ----

Write-Head

try {
    $local = Get-LocalRoot
    if ($local) {
        if ($InPlace -or (Test-SamePath $local $InstallDir)) {
            Write-Ok "Using the copy in $local"
            $root = $local
        } else {
            Write-Step "Copying to $InstallDir..."
            $root = Copy-RepoInto -Source $local -Destination $InstallDir
        }
    } else {
        $root = Get-RepoFromWeb -Destination $InstallDir
    }

    if (-not $SkipPoppler) { Install-Poppler -SourceRoot $root }

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
