#!/usr/bin/env bash
set -euo pipefail

# install.sh — download & install the right nocturne-miner binary for this machine.
# Usage: ./install.sh [--local] [--tag vX.Y.Z]
#   env: BIN_DIR=~/.local/bin (default)
#
# Downloads from: https://cdn.nocturne.offchain.club/releases/

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LOCAL_INSTALL=false
TAG_OVERRIDE=""
CDN_BASE="https://cdn.nocturne.offchain.club/releases"
USE_METADATA=1
file_names=""

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      LOCAL_INSTALL=true
      shift
      ;;
    --tag|-t)
      shift
      [[ $# -gt 0 ]] || die "--tag requires a value like v1.2.3"
      TAG_OVERRIDE="$1"
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--local] [--tag vX.Y.Z]

Downloads the correct archive for this machine and installs to:
  BIN_DIR=${BIN_DIR} (or current directory if --local is used)

Options:
  --local        Download to current directory instead of installing to PATH
  --tag, -t      Install a specific tag instead of the latest (e.g. v1.2.3)
Env:
  BIN_DIR        Installation directory (default: ${BIN_DIR})
EOF
      exit 0
      ;;
    *)
      die "unknown arg: $1 (use --help)"
      ;;
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

# Detect best x86-64 tier (v2/v3/v4) based on CPU flags
detect_x86_tier() {
  local tier="v2"  # safe default

  if [[ "$os" == "linux" ]]; then
    if [[ -r /proc/cpuinfo ]]; then
      local flags
      flags=$(grep -m1 '^flags' /proc/cpuinfo || true)
      has_flag() { [[ " $flags " == *" $1 "* ]]; }

      # v4 = AVX-512 core set
      if has_flag avx512f && has_flag avx512dq && has_flag avx512cd && has_flag avx512bw && has_flag avx512vl; then
        tier="v4"
      # v3 = AVX2 + BMI1 + BMI2 + FMA
      elif has_flag avx2 && has_flag bmi1 && has_flag bmi2 && has_flag fma; then
        tier="v3"
      else
        tier="v2"
      fi
    fi
  elif [[ "$os" == "macos" ]]; then
    local feats=""
    feats+=" $(sysctl -n machdep.cpu.features 2>/dev/null || true)"
    feats+=" $(sysctl -n machdep.cpu.leaf7_features 2>/dev/null || true)"

    if [[ "$feats" == *" AVX512F "* ]]; then
      tier="v4"
    elif [[ "$feats" == *" AVX2 "* || "$feats" == *" AVX2.0 "* ]]; then
      tier="v3"
    else
      tier="v2"
    fi
  fi

  echo "$tier"
}

tier=""
if [[ "$arch" == "x64" ]]; then
  tier=$(detect_x86_tier)
  echo "info: detected x86-64 tier: ${tier}"
fi

# If user forces a tag, we don't rely on latest.json for file list
if [[ -n "$TAG_OVERRIDE" ]]; then
  USE_METADATA=0
  tag="$TAG_OVERRIDE"
  echo "info: using tag override: $tag"
else
  USE_METADATA=1
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

  # Parse all file names from metadata
  file_names=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$metadata" | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  [[ -n "$file_names" ]] || die "no files listed in metadata"
fi

# For --tag mode we still need a tmpdir + trap, if not already created
if [[ -z "${tmpdir:-}" ]]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
fi

probe_asset() {
  # Lightweight existence check for a single asset file name
  local name="$1"
  local url="${CDN_BASE}/${tag}/${name}"
  curl -fsI --retry 2 --retry-delay 1 "$url" >/dev/null 2>&1
}

has_asset() {
  local name="$1"
  if [[ "$USE_METADATA" -eq 1 ]]; then
    printf '%s\n' "$file_names" | grep -Fxq "$name"
  else
    probe_asset "$name"
  fi
}

select_asset_file() {
  # Linux
  if [[ "$os" == "linux" ]]; then
    if [[ "$arch" == "x64" ]]; then
      local base
      if [[ "$libc_suffix" == "-musl" ]]; then
        base="nocturne-miner-linux-musl-x64"
      else
        base="nocturne-miner-linux-x64"
      fi

      local tiers=()
      if [[ -n "${tier:-}" ]]; then
        case "$tier" in
          v4) tiers=(v4 v3 v2) ;;
          v3) tiers=(v3 v2) ;;
          v2|*) tiers=(v2) ;;
        esac
      fi

      local t candidate
      for t in "${tiers[@]}"; do
        candidate="${base}-${t}.tar.gz"
        if has_asset "$candidate"; then
          echo "$candidate"; return 0
        fi
      done

      # Fallback to non-tiered asset for older releases
      candidate="${base}.tar.gz"
      if has_asset "$candidate"; then
        echo "$candidate"; return 0
      fi

      die "no matching linux x64 asset found for base $base (tier=$tier, tag=$tag)"
    elif [[ "$arch" == "arm64" ]]; then
      local candidate
      if [[ "$libc_suffix" == "-musl" ]]; then
        candidate="nocturne-miner-linux-musl-arm64.tar.gz"
      else
        candidate="nocturne-miner-linux-arm64.tar.gz"
      fi
      if has_asset "$candidate"; then
        echo "$candidate"; return 0
      fi
      die "no matching linux arm64 asset found (tag=$tag)"
    fi

  # macOS
  elif [[ "$os" == "macos" ]]; then
    if [[ "$arch" == "x64" ]]; then
      local base="nocturne-miner-macos-x64"
      local tiers=()
      if [[ -n "${tier:-}" ]]; then
        case "$tier" in
          v4) tiers=(v4 v3 v2) ;;
          v3) tiers=(v3 v2) ;;
          v2|*) tiers=(v2) ;;
        esac
      fi

      local t candidate
      for t in "${tiers[@]}"; do
        candidate="${base}-${t}.tar.gz"
        if has_asset "$candidate"; then
          echo "$candidate"; return 0
        fi
      done

      # Fallback to non-tiered asset for older releases
      candidate="${base}.tar.gz"
      if has_asset "$candidate"; then
        echo "$candidate"; return 0
      fi

      die "no matching macOS x64 asset found for base $base (tier=$tier, tag=$tag)"
    elif [[ "$arch" == "arm64" ]]; then
      local candidate="nocturne-miner-macos-arm64.tar.gz"
      if has_asset "$candidate"; then
        echo "$candidate"; return 0
      fi
      die "no matching macOS arm64 asset found (tag=$tag)"
    fi
  fi

  die "unsupported OS/arch combo: os=$os arch=$arch"
}

asset_file="$(select_asset_file)"

# NEW: log which CPU tier is actually being installed (for tiered builds)
if [[ "$asset_file" =~ -v([0-9])\.tar\.gz$ ]]; then
  cpu_tier="v${BASH_REMATCH[1]}"
  echo "info: installing tiered binary: ${cpu_tier} (${asset_file})"
else
  echo "info: installing legacy (non-tiered) binary: ${asset_file}"
fi

url="${CDN_BASE}/${tag}/${asset_file}"
echo "info: downloading ${url}"

archive="$tmpdir/${asset_file}"
curl -fL --retry 3 --retry-delay 2 -o "$archive" "$url" \
  || die "failed to download: $url (wrong URL or unsupported target?)"

echo "info: extracting ${asset_file}"
tar -xzf "$archive" -C "$tmpdir"

# Try to find an executable that looks like nocturne-miner
bin_src="$(find "$tmpdir" -maxdepth 3 -type f -perm -111 -name 'nocturne-miner*' | head -n1 || true)"
[[ -n "$bin_src" ]] || die "could not locate executable inside archive"

install_path="${BIN_DIR}/nocturne-miner"
mv "$bin_src" "$install_path"
chmod +x "$install_path"

echo "success: installed nocturne-miner -> ${install_path}"

# PATH hint (skip for local install)
if [[ "$LOCAL_INSTALL" != "true" ]]; then
  case ":$PATH:" in
    *:"$BIN_DIR":*) ;;
    *) echo "note: ${BIN_DIR} is not in PATH. Add this to your shell rc:";
       echo "      export PATH=\"$BIN_DIR:\$PATH\"";;
  esac
fi
