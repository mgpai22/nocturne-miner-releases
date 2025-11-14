#!/usr/bin/env pwsh
# install.ps1 — download & install the right nocturne-miner binary for this machine.
# Usage: .\install.ps1 [-Local] [-Tag vX.Y.Z]
#   env: $env:BIN_DIR (default: ~/.local/bin on Linux/macOS, ~\AppData\Local\Programs on Windows)
#
# Downloads from: https://cdn.nocturne.offchain.club/releases/

param(
    [Parameter(Mandatory = $false)]
    [switch]$Local,

    [Parameter(Mandatory = $false)]
    [switch]$Help,

    [Parameter(Mandatory = $false)]
    [string]$Tag
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
    $IsWindowsOS = $IsWindows -or ($PSVersionTable.PSVersion.Major -lt 6)
    $defaultBinDir = if ($IsWindowsOS) {
        "$env:USERPROFILE\AppData\Local\Programs"
    }
    else {
        "$env:HOME/.local/bin"
    }

    Write-Host @"
Usage: .\install.ps1 [-Local] [-Tag vX.Y.Z]

Downloads the correct archive for this machine and installs to:
  BIN_DIR=$defaultBinDir (or current directory if -Local is used)

Options:
  -Local         Download to current directory instead of installing to PATH
  -Tag vX.Y.Z    Install a specific tag instead of the latest (e.g. v1.2.3)
Env:
  `$env:BIN_DIR    Installation directory override
"@
    exit 0
}

# Set defaults
$IsWindowsOS = $IsWindows -or ($PSVersionTable.PSVersion.Major -lt 6)
$defaultBinDir = if ($IsWindowsOS) {
    "$env:USERPROFILE\AppData\Local\Programs"
}
else {
    "$env:HOME/.local/bin"
}

$CdnBase     = "https://cdn.nocturne.offchain.club/releases"
$BinDir      = if ($env:BIN_DIR) { $env:BIN_DIR } else { $defaultBinDir }
$LocalInstall = $Local.IsPresent
$TagOverride  = $Tag
$UseMetadata  = $true
[string[]]$fileNames = @()

if ($LocalInstall) {
    $BinDir = "."
}
else {
    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    }
}

# Detect OS
if ($IsWindowsOS) {
    $os = "windows"
}
elseif ($IsMacOS) {
    $os = "macos"
}
elseif ($IsLinux) {
    $os = "linux"
}
else {
    Write-Error-Exit "unsupported OS"
}

# Detect architecture
$arch = if ($env:PROCESSOR_ARCHITECTURE) {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { "x64" }
        "ARM64" { "arm64" }
        default { Write-Error-Exit "unsupported CPU arch: $env:PROCESSOR_ARCHITECTURE" }
    }
}
else {
    $unameM = uname -m 2>$null
    if ($unameM) {
        switch ($unameM) {
            "x86_64" { "x64" }
            "amd64"  { "x64" }
            "aarch64" { "arm64" }
            "arm64"   { "arm64" }
            default { Write-Error-Exit "unsupported CPU arch: $unameM" }
        }
    }
    else {
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
    }
    catch {
        # Ignore errors
    }
}

# musl vs glibc detection for Linux
$libcSuffix = ""
if ($os -eq "linux") {
    if (Test-Path "/etc/alpine-release") {
        $libcSuffix = "-musl"
    }
    else {
        try {
            $lddVersion = ldd --version 2>&1
            if ($lddVersion -match "musl") {
                $libcSuffix = "-musl"
            }
        }
        catch {
            # Ignore errors
        }
    }
}

# x86-64 tier detection (Linux/macOS only)
function Get-X86Tier {
    param([string]$Os)

    $tier = "v2" # safe default

    if ($Os -eq "linux") {
        if (Test-Path "/proc/cpuinfo") {
            try {
                $line = Get-Content /proc/cpuinfo | Select-String -Pattern "^flags" -SimpleMatch -CaseSensitive:$false | Select-Object -First 1
                if ($line) {
                    $flags = $line.Line
                    function Has-Flag([string]$flag) {
                        return $flags -match "(^|\s)$([regex]::Escape($flag))(\s|$)"
                    }

                    # v4 = AVX-512 core set
                    if (Has-Flag "avx512f" -and Has-Flag "avx512dq" -and Has-Flag "avx512cd" -and Has-Flag "avx512bw" -and Has-Flag "avx512vl") {
                        $tier = "v4"
                    }
                    # v3 = AVX2 + BMI1 + BMI2 + FMA
                    elseif (Has-Flag "avx2" -and Has-Flag "bmi1" -and Has-Flag "bmi2" -and Has-Flag "fma") {
                        $tier = "v3"
                    }
                    else {
                        $tier = "v2"
                    }
                }
            }
            catch {
                # fall back to default v2
            }
        }
    }
    elseif ($Os -eq "macos") {
        try {
            $features  = (sysctl -n machdep.cpu.features 2>$null)
            $features2 = (sysctl -n machdep.cpu.leaf7_features 2>$null)
            $feats = "$features $features2"

            if ($feats -like "* AVX512F *") {
                $tier = "v4"
            }
            elseif ($feats -like "* AVX2 *" -or $feats -like "* AVX2.0 *") {
                $tier = "v3"
            }
            else {
                $tier = "v2"
            }
        }
        catch {
            # fall back to default v2
        }
    }

    return $tier
}

$tier = $null
if ($arch -eq "x64" -and ($os -eq "linux" -or $os -eq "macos")) {
    $tier = Get-X86Tier -Os $os
    Write-Host "info: detected x86-64 tier: $tier"
}

# Determine tag (latest or override)
if ([string]::IsNullOrWhiteSpace($TagOverride)) {
    $UseMetadata = $true
    $latestJsonUrl = "$CdnBase/latest.json"
    Write-Host "info: fetching latest release metadata..."

    try {
        $latestJson = Invoke-RestMethod -Uri $latestJsonUrl -UseBasicParsing
        $tag = $latestJson.tag
        if (-not $tag) {
            Write-Error-Exit "could not parse version tag from metadata"
        }
        Write-Host "info: latest version: $tag"

        if ($latestJson.files) {
            $fileNames = @($latestJson.files.name)
        }
        else {
            Write-Error-Exit "no files listed in metadata"
        }
    }
    catch {
        Write-Error-Exit "failed to fetch release metadata from $latestJsonUrl : $_"
    }
}
else {
    $UseMetadata = $false
    $tag = $TagOverride
    Write-Host "info: using tag override: $tag"
}

$target = "$os$libcSuffix-$arch"
$muslInfo = if ($libcSuffix) { "yes" } else { "no" }
Write-Host "info: OS=$os ARCH=$arch MUSL=$muslInfo -> target=$target"

function Has-Asset {
    param([string]$Name)

    if ($UseMetadata) {
        return $fileNames -contains $Name
    }
    else {
        $url = "$CdnBase/$tag/$Name"
        try {
            $resp = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -lt 400) { return $true } else { return $false }
        }
        catch {
            return $false
        }
    }
}

function Select-AssetFile {
    param(
        [string]$Os,
        [string]$Arch,
        [string]$LibcSuffix,
        [string]$Tier
    )

    # Linux
    if ($Os -eq "linux") {
        if ($Arch -eq "x64") {
            $base = if ($LibcSuffix -eq "-musl") {
                "nocturne-miner-linux-musl-x64"
            }
            else {
                "nocturne-miner-linux-x64"
            }

            $tiers = @()
            if ($Tier) {
                switch ($Tier) {
                    "v4" { $tiers = @("v4", "v3", "v2") }
                    "v3" { $tiers = @("v3", "v2") }
                    default { $tiers = @("v2") }
                }
            }

            foreach ($t in $tiers) {
                $candidate = "$base-$t.tar.gz"
                if (Has-Asset $candidate) { return $candidate }
            }

            $fallback = "$base.tar.gz"
            if (Has-Asset $fallback) { return $fallback }

            Write-Error-Exit "no matching linux x64 asset found for base $base (tier=$Tier, tag=$tag)"
        }
        elseif ($Arch -eq "arm64") {
            $candidate = if ($LibcSuffix -eq "-musl") {
                "nocturne-miner-linux-musl-arm64.tar.gz"
            }
            else {
                "nocturne-miner-linux-arm64.tar.gz"
            }
            if (Has-Asset $candidate) { return $candidate }
            Write-Error-Exit "no matching linux arm64 asset found (tag=$tag)"
        }
    }

    # macOS
    if ($Os -eq "macos") {
        if ($Arch -eq "x64") {
            $base = "nocturne-miner-macos-x64"
            $tiers = @()
            if ($Tier) {
                switch ($Tier) {
                    "v4" { $tiers = @("v4", "v3", "v2") }
                    "v3" { $tiers = @("v3", "v2") }
                    default { $tiers = @("v2") }
                }
            }

            foreach ($t in $tiers) {
                $candidate = "$base-$t.tar.gz"
                if (Has-Asset $candidate) { return $candidate }
            }

            $fallback = "$base.tar.gz"
            if (Has-Asset $fallback) { return $fallback }

            Write-Error-Exit "no matching macOS x64 asset found for base $base (tier=$Tier, tag=$tag)"
        }
        elseif ($Arch -eq "arm64") {
            $candidate = "nocturne-miner-macos-arm64.tar.gz"
            if (Has-Asset $candidate) { return $candidate }
            Write-Error-Exit "no matching macOS arm64 asset found (tag=$tag)"
        }
    }

    # Windows
    if ($Os -eq "windows") {
        if ($Arch -eq "x64") {
            # Safe strategy: prefer v2 if present (baseline x86-64 features), then legacy.
            $candidates = @(
                "nocturne-miner-windows-x64-v2.zip",
                "nocturne-miner-windows-x64.zip"
            )

            foreach ($c in $candidates) {
                if (Has-Asset $c) { return $c }
            }

            Write-Error-Exit "no matching Windows x64 asset found (tag=$tag)"
        }
        elseif ($Arch -eq "arm64") {
            $candidate = "nocturne-miner-windows-arm64.zip"
            if (Has-Asset $candidate) { return $candidate }
            Write-Error-Exit "no matching Windows arm64 asset found (tag=$tag)"
        }
    }

    Write-Error-Exit "unsupported OS/arch combo: os=$Os arch=$Arch"
}

$assetFile = Select-AssetFile -Os $os -Arch $arch -LibcSuffix $libcSuffix -Tier $tier

# Log tier vs legacy based on filename
if ($assetFile -match "-v([0-9])\.(zip|tar\.gz)$") {
    $cpuTier = "v$($Matches[1])"
    Write-Host "info: installing tiered binary: $cpuTier ($assetFile)"
}
else {
    Write-Host "info: installing legacy (non-tiered) binary: $assetFile"
}

$downloadUrl = "$CdnBase/$tag/$assetFile"
Write-Host "info: downloading $downloadUrl"

# Create temp directory
$tmpDir = Join-Path $env:TEMP "nocturne-miner-install-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

try {
    $archive = Join-Path $tmpDir $assetFile

    # Download with retry
    $maxRetries = 3
    $retryDelay = 2
    $downloaded = $false

    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $archive -UseBasicParsing
            $downloaded = $true
            break
        }
        catch {
            if ($i -lt $maxRetries) {
                Write-Host "warning: download attempt $i failed, retrying in ${retryDelay}s..."
                Start-Sleep -Seconds $retryDelay
            }
        }
    }

    if (-not $downloaded) {
        Write-Error-Exit "failed to download: $downloadUrl (wrong URL or unsupported target?)"
    }

    Write-Host "info: extracting $assetFile"

    $lowerName = $assetFile.ToLowerInvariant()
    $isZip = $lowerName.EndsWith(".zip")

    # Extract archive
    if ($isZip) {
        Expand-Archive -Path $archive -DestinationPath $tmpDir -Force
    }
    else {
        if (Test-Command "tar") {
            tar -xzf $archive -C $tmpDir
            if ($LASTEXITCODE -ne 0) {
                Write-Error-Exit "tar extraction failed"
            }
        }
        else {
            Write-Error-Exit "tar command not found (required for .tar.gz extraction)"
        }
    }

    # Find executable
    $binSrc = Get-ChildItem -Path $tmpDir -Recurse -File -Depth 3 |
        Where-Object {
            $_.Name -like "nocturne-miner*" -and
            ($_.Extension -eq ".exe" -or $_.Extension -eq "" -or $_.UnixFileMode)
        } |
        Select-Object -First 1

    if (-not $binSrc) {
        Write-Error-Exit "could not locate executable inside archive"
    }

    # Set install path (add .exe on Windows if not present)
    $installName = "nocturne-miner"
    if ($IsWindowsOS -and -not $installName.EndsWith(".exe")) {
        $installName += ".exe"
    }
    $installPath = Join-Path $BinDir $installName

    # Move binary
    Move-Item -Path $binSrc.FullName -Destination $installPath -Force

    # Set executable permissions on Unix-like systems
    if (-not $IsWindowsOS) {
        chmod +x $installPath
    }

    Write-Host "success: installed nocturne-miner -> $installPath" -ForegroundColor Green

    # PATH hint (skip for local install)
    if (-not $LocalInstall) {
        $pathSep = if ($IsWindowsOS) { ";" } else { ":" }
        $currentPath = $env:PATH
        if (-not $currentPath.Split($pathSep).Contains($BinDir)) {
            Write-Host "note: $BinDir is not in PATH. Add this to your profile:"
            if ($IsWindowsOS) {
                Write-Host "      `$env:PATH = `"$BinDir;`$env:PATH`""
            }
            else {
                Write-Host "      export PATH=`"$BinDir`:`$PATH`""
            }
        }
    }
}
finally {
    # Cleanup
    Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
