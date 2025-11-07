#!/usr/bin/env bash
set -euo pipefail

# install.sh — download & install the right nocturne-miner binary for this machine.
# Usage: ./install.sh [--local]
#   env: BIN_DIR=~/.local/bin (default)
#        NAME=nocturne-miner (installed executable name, default)
#
# Downloads from: https://cdn.nocturne.offchain.club/releases/

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
NAME="${NAME:-nocturne-miner}"
LOCAL_INSTALL=false
CDN_BASE="https://cdn.nocturne.offchain.club/releases"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) LOCAL_INSTALL=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--local]

Downloads the correct archive for this machine and installs to:
  BIN_DIR=${BIN_DIR} (or current directory if --local is used)

Options:
  --local        Download to current directory instead of installing to PATH
Env:
  BIN_DIR        Installation directory (default: ${BIN_DIR})
  NAME           Installed executable name (default: ${NAME})
EOF
      exit 0
      ;;
    *) die "unknown arg: $1 (use --help)";;
  esac
done

need curl
need tar
need grep

if [[ "$LOCAL_INSTALL" == "true" ]]; then
  BIN_DIR="."
else
  mkdir -p "$BIN_DIR"
fi

# Fetch latest release info
echo "info: fetching latest release metadata..."
latest_json="${CDN_BASE}/latest.json"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

metadata="$tmpdir/latest.json"
curl -fL --retry 3 --retry-delay 2 -o "$metadata" "$latest_json" \
  || die "failed to fetch release metadata from $latest_json"

# Parse version tag from JSON (simple grep approach)
tag=$(grep -o '"tag"[[:space:]]*:[[:space:]]*"[^"]*"' "$metadata" | head -n1 | sed 's/.*"tag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ -n "$tag" ]] || die "could not parse version tag from metadata"

echo "info: latest version: $tag"

uname_s=$(uname -s)
uname_m=$(uname -m)

# Determine OS target
case "$uname_s" in
  Linux)   os="linux" ;;
  Darwin)  os="macos" ;;
  *)       die "unsupported OS: $uname_s" ;;
esac

# Determine arch (normalize common aliases)
case "$uname_m" in
  x86_64|amd64) arch="x64" ;;
  aarch64|arm64) arch="arm64" ;;
  *) die "unsupported CPU arch: $uname_m" ;;
esac

# On macOS, if running under Rosetta, prefer arm64 build
if [[ "$os" == "macos" && "$arch" == "x64" ]]; then
  if sysctl -n sysctl.proc_translated 2>/dev/null | grep -q '^1$'; then
    echo "info: Rosetta detected; using macos-arm64 build"
    arch="arm64"
  fi
fi

# musl vs glibc detection for Linux
libc_suffix=""
if [[ "$os" == "linux" ]]; then
  if [[ -f /etc/alpine-release ]] || ldd --version 2>&1 | grep -qi musl; then
    libc_suffix="-musl"
  fi
fi

target="${os}${libc_suffix}-${arch}"
file="nocturne-miner-${target}.tar.gz"
url="${CDN_BASE}/${tag}/${file}"

echo "info: OS=${os} ARCH=${arch} MUSL=${libc_suffix:+yes} -> target=${target}"
echo "info: downloading ${url}"

archive="$tmpdir/${file}"
curl -fL --retry 3 --retry-delay 2 -o "$archive" "$url" \
  || die "failed to download: $url (wrong URL or unsupported target?)"

echo "info: extracting ${file}"
tar -xzf "$archive" -C "$tmpdir"

# Try to find an executable that looks like nocturne-miner
bin_src="$(find "$tmpdir" -maxdepth 3 -type f -perm -111 -name 'nocturne-miner*' | head -n1 || true)"
[[ -n "$bin_src" ]] || die "could not locate executable inside archive"

install_path="${BIN_DIR}/${NAME}"
mv "$bin_src" "$install_path"
chmod +x "$install_path"

echo "success: installed ${NAME} -> ${install_path}"

# PATH hint (skip for local install)
if [[ "$LOCAL_INSTALL" != "true" ]]; then
  case ":$PATH:" in
    *:"$BIN_DIR":*) ;;
    *) echo "note: ${BIN_DIR} is not in PATH. Add this to your shell rc:"; echo "      export PATH=\"$BIN_DIR:\$PATH\"";;
  esac
fi