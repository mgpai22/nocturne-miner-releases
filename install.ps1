#!/usr/bin/env pwsh
# install.ps1 — download & install the right nocturne-miner binary for this machine.
# Usage: .\install.ps1 [-Local]
#   env: $env:BIN_DIR (default: ~/.local/bin on Linux/macOS, ~\AppData\Local\Programs on Windows)
#        $env:NAME (installed executable name, default: nocturne-miner)
#
# Downloads from: https://cdn.nocturne.offchain.club/releases/

param(
    [Parameter(Mandatory=$false)]
    [switch]$Local,
    
    [Parameter(Mandatory=$false)]
    [switch]$Help
)

$ErrorActionPreference = "Stop"

function Write-Error-Exit {
    param([string]$Message)
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

function Test-Command {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

if ($Help) {
    $defaultBinDir = if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) {
        "$env:USERPROFILE\AppData\Local\Programs"
    } else {
        "$env:HOME/.local/bin"
    }
    
    Write-Host @"
Usage: .\install.ps1 [-Local]

Downloads the correct archive for this machine and installs to:
  BIN_DIR=$defaultBinDir (or current directory if -Local is used)

Options:
  -Local         Download to current directory instead of installing to PATH
Env:
  `$env:BIN_DIR    Installation directory
  `$env:NAME       Installed executable name (default: nocturne-miner)
"@
    exit 0
}

# Set defaults
$IsWindowsOS = $IsWindows -or ($PSVersionTable.PSVersion.Major -lt 6)
$defaultBinDir = if ($IsWindowsOS) {
    "$env:USERPROFILE\AppData\Local\Programs"
} else {
    "$env:HOME/.local/bin"
}

$CdnBase = "https://cdn.nocturne.offchain.club/releases"
$BinDir = if ($env:BIN_DIR) { $env:BIN_DIR } else { $defaultBinDir }
$Name = if ($env:NAME) { $env:NAME } else { "nocturne-miner" }
$LocalInstall = $Local.IsPresent

if ($LocalInstall) {
    $BinDir = "."
} else {
    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    }
}

# Fetch latest release info
Write-Host "info: fetching latest release metadata..."
$latestJsonUrl = "$CdnBase/latest.json"

try {
    $latestJson = Invoke-RestMethod -Uri $latestJsonUrl -UseBasicParsing
    $tag = $latestJson.tag
    if (-not $tag) {
        Write-Error-Exit "could not parse version tag from metadata"
    }
    Write-Host "info: latest version: $tag"
} catch {
    Write-Error-Exit "failed to fetch release metadata from $latestJsonUrl : $_"
}

# Detect OS
if ($IsWindowsOS) {
    $os = "windows"
} elseif ($IsMacOS) {
    $os = "macos"
} elseif ($IsLinux) {
    $os = "linux"
} else {
    Write-Error-Exit "unsupported OS"
}

# Detect architecture
$arch = if ($env:PROCESSOR_ARCHITECTURE) {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { "x64" }
        "ARM64" { "arm64" }
        default { Write-Error-Exit "unsupported CPU arch: $env:PROCESSOR_ARCHITECTURE" }
    }
} else {
    $unameM = uname -m 2>$null
    if ($unameM) {
        switch ($unameM) {
            "x86_64" { "x64" }
            "amd64" { "x64" }
            "aarch64" { "arm64" }
            "arm64" { "arm64" }
            default { Write-Error-Exit "unsupported CPU arch: $unameM" }
        }
    } else {
        Write-Error-Exit "unable to determine CPU architecture"
    }
}

# On macOS, if running under Rosetta, prefer arm64 build
if ($os -eq "macos" -and $arch -eq "x64") {
    try {
        $rosetta = sysctl -n sysctl.proc_translated 2>$null
        if ($rosetta -eq "1") {
            Write-Host "info: Rosetta detected; using macos-arm64 build"
            $arch = "arm64"
        }
    } catch {
        # Ignore errors
    }
}

# musl vs glibc detection for Linux
$libcSuffix = ""
if ($os -eq "linux") {
    if (Test-Path "/etc/alpine-release") {
        $libcSuffix = "-musl"
    } else {
        try {
            $lddVersion = ldd --version 2>&1
            if ($lddVersion -match "musl") {
                $libcSuffix = "-musl"
            }
        } catch {
            # Ignore errors
        }
    }
}

$target = "$os$libcSuffix-$arch"
$extension = if ($os -eq "windows") { "zip" } else { "tar.gz" }
$file = "nocturne-miner-$target.$extension"
$downloadUrl = "$CdnBase/$tag/$file"

$muslInfo = if ($libcSuffix) { "yes" } else { "no" }
Write-Host "info: OS=$os ARCH=$arch MUSL=$muslInfo -> target=$target"
Write-Host "info: downloading $downloadUrl"

# Create temp directory
$tmpDir = Join-Path $env:TEMP "nocturne-miner-install-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

try {
    $archive = Join-Path $tmpDir $file
    
    # Download with retry
    $maxRetries = 3
    $retryDelay = 2
    $downloaded = $false
    
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $archive -UseBasicParsing
            $downloaded = $true
            break
        } catch {
            if ($i -lt $maxRetries) {
                Write-Host "warning: download attempt $i failed, retrying in ${retryDelay}s..."
                Start-Sleep -Seconds $retryDelay
            }
        }
    }
    
    if (-not $downloaded) {
        Write-Error-Exit "failed to download: $downloadUrl (wrong URL or unsupported target?)"
    }
    
    Write-Host "info: extracting $file"
    
    # Extract archive
    if ($extension -eq "zip") {
        Expand-Archive -Path $archive -DestinationPath $tmpDir -Force
    } else {
        # Use tar on Unix-like systems or Windows with tar available
        if (Test-Command "tar") {
            tar -xzf $archive -C $tmpDir
            if ($LASTEXITCODE -ne 0) {
                Write-Error-Exit "tar extraction failed"
            }
        } else {
            Write-Error-Exit "tar command not found (required for .tar.gz extraction)"
        }
    }
    
    # Find executable
    $binSrc = Get-ChildItem -Path $tmpDir -Recurse -File -Depth 3 |
        Where-Object { $_.Name -like "nocturne-miner*" -and ($_.Extension -eq ".exe" -or $_.Extension -eq "" -or $_.UnixFileMode) } |
        Select-Object -First 1
    
    if (-not $binSrc) {
        Write-Error-Exit "could not locate executable inside archive"
    }
    
    # Set install path (add .exe on Windows if not present)
    $installName = $Name
    if ($os -eq "windows" -and $installName -notlike "*.exe") {
        $installName += ".exe"
    }
    $installPath = Join-Path $BinDir $installName
    
    # Move binary
    Move-Item -Path $binSrc.FullName -Destination $installPath -Force
    
    # Set executable permissions on Unix-like systems
    if (-not $IsWindowsOS) {
        chmod +x $installPath
    }
    
    Write-Host "success: installed $Name -> $installPath" -ForegroundColor Green
    
    # PATH hint (skip for local install)
    if (-not $LocalInstall) {
        $pathSep = if ($IsWindowsOS) { ";" } else { ":" }
        $currentPath = $env:PATH
        if (-not $currentPath.Split($pathSep).Contains($BinDir)) {
            Write-Host "note: $BinDir is not in PATH. Add this to your profile:"
            if ($IsWindowsOS) {
                Write-Host "      `$env:PATH = `"$BinDir;`$env:PATH`""
            } else {
                Write-Host "      export PATH=`"$BinDir`:`$PATH`""
            }
        }
    }
} finally {
    # Cleanup
    Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

