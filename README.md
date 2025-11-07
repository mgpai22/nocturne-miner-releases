# Nocturne Miner Releases

Installation scripts for the nocturne-miner binary.

## Quick Install

### Bash (Linux/macOS)
```bash
curl -fsSL https://raw.githubusercontent.com/mgpai22/nocturne-miner-releases/main/install.sh | bash
```

### PowerShell (Windows/Linux/macOS)
```powershell
irm https://raw.githubusercontent.com/mgpai22/nocturne-miner-releases/main/install.ps1 | iex
```

## Installation

### Option 1: Install to PATH

**Bash:**
```bash
# Download install script
curl -fsSL https://raw.githubusercontent.com/mgpai22/nocturne-miner-releases/main/install.sh -o install.sh
chmod +x install.sh

# Install binary to ~/.local/bin
./install.sh
```

**PowerShell:**
```powershell
# Download install script
Invoke-WebRequest -Uri https://raw.githubusercontent.com/mgpai22/nocturne-miner-releases/main/install.ps1 -OutFile install.ps1

# Install binary to PATH
.\install.ps1
```

**Default install locations:**
- Linux/macOS: `~/.local/bin/nocturne-miner`
- Windows: `%USERPROFILE%\AppData\Local\Programs\nocturne-miner.exe`

### Option 2: Install to Current Directory

Use the `--local` flag (bash) or `-Local` flag (PowerShell) to download the binary to the current directory instead of installing to PATH.

**Bash:**
```bash
./install.sh --local
```

**PowerShell:**
```powershell
.\install.ps1 -Local
```

This is useful for:
- Running the miner in a specific directory
- Testing without modifying your PATH
- Portable installations

## Usage

**Direct execution:**
```bash
# If installed to PATH
nocturne-miner [args]

# If installed locally
./nocturne-miner [args]
```