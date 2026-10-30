#!/usr/bin/env bash
# Installs (or updates) Neovim from the official GitHub release, for machines whose package manager ships an old one
# (Ubuntu's apt). The release is unpacked into $NVIM_INSTALL_DIR/nvim-<version>-<platform> and linked as
# $NVIM_BIN_DIR/nvim, so an update only swaps the link and the previous version stays until removed.
#
# Usage: scripts/install-nvim.sh [--version stable|nightly|vX.Y.Z] [--force] [--tarball]
#   --version  release to install (default: stable)
#   --force    reinstall even when that version is already the one linked
#   --tarball  on macOS, use the release tarball even when Homebrew is available
# Environment: NVIM_INSTALL_DIR (default ~/.local/opt), NVIM_BIN_DIR (default ~/.local/bin)
set -euo pipefail

version=stable
force=false
use_tarball=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:?--version needs a value}"; shift 2 ;;
    --force) force=true; shift ;;
    --tarball) use_tarball=true; shift ;;
    -h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

install_dir="${NVIM_INSTALL_DIR:-$HOME/.local/opt}"
bin_dir="${NVIM_BIN_DIR:-$HOME/.local/bin}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"

os="$(uname -s)"
arch="$(uname -m)"

# macOS: Homebrew keeps Neovim current, so prefer it
if [[ "$os" == Darwin && "$use_tarball" == false && "$version" == stable ]] && command -v brew >/dev/null; then
  if brew list --formula neovim >/dev/null 2>&1; then
    log "Upgrading Neovim with Homebrew"
    # Already current is only a warning (exit 0); a failure here, or a pinned neovim, is real
    brew upgrade neovim
  else
    log "Installing Neovim with Homebrew"
    brew install neovim
  fi
  nvim --version | head -1
  exit 0
fi

# Release asset names (https://github.com/neovim/neovim/releases)
case "$os/$arch" in
  Linux/x86_64 | Linux/amd64) platform=linux-x86_64 ;;
  Linux/aarch64 | Linux/arm64) platform=linux-arm64 ;;
  Darwin/arm64) platform=macos-arm64 ;;
  Darwin/x86_64) platform=macos-x86_64 ;;
  *) die "no prebuilt Neovim release for $os/$arch; build from source: https://github.com/neovim/neovim/blob/master/BUILD.md" ;;
esac
asset="nvim-$platform.tar.gz"

# The tag the release resolves to (stable → vX.Y.Z), to name the install and skip one already installed
resolve_tag() {
  if [[ "$version" == v* ]]; then
    echo "$version"
    return
  fi
  local api="https://api.github.com/repos/neovim/neovim/releases"
  [[ "$version" == stable ]] && api="$api/latest" || api="$api/tags/$version"
  curl -fsSL "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}
tag="$(resolve_tag || true)"
[[ -n "$tag" ]] || die "could not resolve the '$version' release (GitHub API rate limit? pass --version vX.Y.Z)"

# nightly keeps its tag: always fetch it again
current=""
if command -v nvim >/dev/null; then current="$(nvim --version 2>/dev/null | head -1 | awk '{print $2}')"; fi
if [[ "$force" == false && "$tag" != nightly && "$current" == "$tag" && "$(command -v nvim)" == "$bin_dir/nvim" ]]; then
  log "Neovim $tag is already installed ($bin_dir/nvim); --force to reinstall"
  exit 0
fi

target="$install_dir/nvim-$tag-$platform"
url="https://github.com/neovim/neovim/releases/download/$tag/$asset"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "Downloading $url"
curl -fL --progress-bar -o "$tmp/$asset" "$url" || die "download failed: $url"
tar -xzf "$tmp/$asset" -C "$tmp"
unpacked="$tmp/nvim-$platform"
[[ -x "$unpacked/bin/nvim" ]] || die "unexpected archive layout: no nvim-$platform/bin/nvim in $asset"

# Runs here before replacing anything (e.g. a glibc too old for the release fails now, not after the switch)
"$unpacked/bin/nvim" --version >/dev/null 2>&1 ||
  die "the downloaded nvim does not run on this machine (glibc too old?); try the AppImage or build from source"

mkdir -p "$install_dir" "$bin_dir"
# Stage next to the target and point the link at it first, so a reinstall of the linked version
# (--force) never leaves $bin_dir/nvim dangling while the old copy is removed
staged="$target.new.$$"
rm -rf "$staged"
mv "$unpacked" "$staged"
ln -sfn "$staged/bin/nvim" "$bin_dir/nvim"
rm -rf "$target"
mv "$staged" "$target"
ln -sfn "$target/bin/nvim" "$bin_dir/nvim"
log "Linked $bin_dir/nvim -> $target/bin/nvim"
"$bin_dir/nvim" --version | head -1

case ":$PATH:" in
  *":$bin_dir:"*)
    resolved="$(command -v nvim)"
    [[ "$resolved" == "$bin_dir/nvim" ]] ||
      log "Note: 'nvim' on PATH is $resolved; put $bin_dir before it in PATH (or remove the apt one: sudo apt remove neovim)"
    ;;
  *) log "Note: $bin_dir is not on PATH; add to your shell rc: export PATH=\"$bin_dir:\$PATH\"" ;;
esac

old="$(find "$install_dir" -maxdepth 1 -name "nvim-*-$platform" ! -path "$target" 2>/dev/null || true)"
[[ -z "$old" ]] || log "Earlier versions kept (remove when no longer needed):"$'\n'"$old"
