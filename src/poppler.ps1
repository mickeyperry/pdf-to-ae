#requires -version 5.1
<#
    poppler.ps1

    Shared Poppler discovery and bootstrap. Dot-sourced by both the installer and
    the worker:

        . (Join-Path $PSScriptRoot 'poppler.ps1')

    The installer and the worker used to carry their own separate search lists,
    which meant a machine could have a perfectly good Poppler that one of them
    found and the other did not. There is now exactly one list, here.
#>

# Where we put Poppler ourselves when winget is unavailable.
function Get-PopplerPrivateRoot {
    Join-Path $env:LOCALAPPDATA 'Programs\pdf-to-ae\poppler'
}

# A Poppler bin folder is only useful if it has all three tools we call.
function Test-PopplerBin {
    param([string] $Dir)
    if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir)) { return $false }
    foreach ($exe in 'pdftocairo.exe', 'pdfinfo.exe', 'pdfseparate.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $exe))) { return $false }
    }
    return $true
}

# Find pdftocairo.exe under a folder without walking the whole tree. Poppler
# distributions bury it two or three levels down (poppler-25.07.0\Library\bin),
# so a bounded depth is both enough and much faster than -Recurse over, say,
# every winget package on the machine.
function Find-PopplerBinUnder {
    param([string] $Root, [int] $Depth = 4)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return $null }
    $hits = Get-ChildItem -LiteralPath $Root -Filter 'pdftocairo.exe' -Recurse -Depth $Depth `
                          -File -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending
    foreach ($h in $hits) {
        if (Test-PopplerBin $h.DirectoryName) { return $h.DirectoryName }
    }
    return $null
}

# Every place Poppler realistically lives on Windows, in priority order.
function Get-PopplerSearchRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    # Our own copy first: if we installed it, it is the one we know is complete.
    $roots.Add((Get-PopplerPrivateRoot))

    # winget, narrowed to the Poppler package so we do not scan every package.
    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetRoot) {
        Get-ChildItem -LiteralPath $wingetRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*Poppler*' } |
            Sort-Object Name -Descending |
            ForEach-Object { $roots.Add($_.FullName) }
    }

    # Manual and package-manager installs. ProgramW6432 is included because a
    # 32-bit host process reports the x86 folder in ProgramFiles, which is how a
    # per-machine install can hide from one caller but not another.
    foreach ($pf in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($pf) { $roots.Add((Join-Path $pf 'poppler')) }
    }
    $roots.Add('C:\poppler')
    $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs\poppler'))
    if ($env:USERPROFILE) { $roots.Add((Join-Path $env:USERPROFILE 'scoop\apps\poppler')) }
    $roots.Add('C:\ProgramData\chocolatey\lib\poppler')

    return $roots | Where-Object { $_ } | Select-Object -Unique
}

# Returns the Poppler bin folder, or $null. Never throws, never installs.
function Resolve-PopplerBin {
    # PATH wins when it is complete - it is what the user chose.
    $probe = Get-Command 'pdftocairo.exe' -ErrorAction SilentlyContinue
    if ($probe -and $probe.Source) {
        $dir = Split-Path -Parent $probe.Source
        if (Test-PopplerBin $dir) { return $dir }
    }

    foreach ($root in (Get-PopplerSearchRoots)) {
        # The root may itself be a bin folder, or contain one further down.
        if (Test-PopplerBin $root) { return $root }
        $hit = Find-PopplerBinUnder -Root $root
        if ($hit) { return $hit }
    }
    return $null
}

# ------------------------------------------------------------------ install ----

function Install-PopplerViaWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $null }

    & winget install --id oschwartz10612.Poppler --source winget `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity 2>&1 | Out-Null

    return (Resolve-PopplerBin)
}

# Fallback for machines with no winget at all (LTSC, Server, un-updated Win10).
# Pulls the official poppler-windows release zip straight from GitHub into our
# own folder, so nothing outside the user profile is touched.
function Install-PopplerFromGitHub {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $api = 'https://api.github.com/repos/oschwartz10612/poppler-windows/releases/latest'
    $headers = @{ 'User-Agent' = 'pdf-to-ae-installer'; 'Accept' = 'application/vnd.github+json' }

    $release = Invoke-RestMethod -Uri $api -Headers $headers -UseBasicParsing
    $asset = $release.assets |
             Where-Object { $_.name -like '*.zip' } |
             Sort-Object { $_.name } -Descending |
             Select-Object -First 1
    if (-not $asset) { throw 'No zip asset found on the latest poppler-windows release.' }

    $dest    = Get-PopplerPrivateRoot
    $tmp     = Join-Path ([System.IO.Path]::GetTempPath()) ("poppler_" + [Guid]::NewGuid().ToString('N'))
    $zipPath = "$tmp.zip"

    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'pdf-to-ae-installer')
        $wc.DownloadFile($asset.browser_download_url, $zipPath)

        [System.IO.Directory]::CreateDirectory($tmp) | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmp -Force

        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $dest)) | Out-Null

        # The zip holds a single "poppler-<version>" folder; keep that shape so
        # the search list finds Library\bin underneath it.
        Move-Item -LiteralPath $tmp -Destination $dest -Force
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    return (Resolve-PopplerBin)
}
