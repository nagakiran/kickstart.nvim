#!/usr/bin/env bash
# Installs what this config needs outside Neovim itself, on macOS (Homebrew) or Ubuntu/Debian (apt).
# Neovim itself: scripts/install-nvim.sh. LSP servers, formatters and debug adapters: Mason, on first start.
#
# Usage: scripts/install-deps.sh [step...]     (no step: all of them, in this order)
#   system   build tools, ripgrep, clipboard; on Linux also pyenv's Python build dependencies
#   pyenv    pyenv itself
#   python   pyenv Python $PYTHON_VERSION and the 'myenv' venv with pynvim (python3_host_prog, pyright's venv)
#   node     nvm and Node $NODE_MAJOR (copilot.lua needs 22+; Mason's npm-based servers need node on PATH)
#   treesitter  the tree-sitter CLI $TS_MIN_VERSION+, which nvim-treesitter's main branch compiles parsers with
# Environment: DRY_RUN=1 prints what would change; PYTHON_VERSION (default 3.13.2); NODE_MAJOR (default 22);
#   BIN_DIR (default ~/.local/bin, where the Linux tree-sitter binary goes)
#
# Every step is idempotent. A failing step is reported and the rest still run; the exit code is non-zero if any failed.
set -uo pipefail

PYTHON_VERSION="${PYTHON_VERSION:-3.13.2}"
NODE_MAJOR="${NODE_MAJOR:-22}"
NVM_VERSION=v0.40.3
# nvim-treesitter (main) README: 0.26.1 or later, from a package manager or the release, not npm
TS_MIN_VERSION=0.26.1
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DRY_RUN="${DRY_RUN:-}"
PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
failed=()

log() { printf '==> %s\n' "$*"; }
skip() { printf '    skip %s\n' "$*"; }
warn() { printf '    warn %s\n' "$*" >&2; }
fail() {
  printf '    FAIL %s\n' "$*" >&2
  failed+=("$*")
}
have() { command -v "$1" >/dev/null 2>&1; }
# The only way anything here changes the machine, so DRY_RUN=1 is trustworthy
run() {
  if [[ -n "$DRY_RUN" ]]; then
    printf '    + %s\n' "$*"
    return 0
  fi
  "$@"
}

case "$(uname -s)" in
  Darwin) os=mac ;;
  Linux) have apt-get && os=apt || os=linux ;;
  *) os=other ;;
esac

brew_install() {
  have brew || {
    fail "Homebrew not installed: https://brew.sh"
    return 1
  }
  local p missing=()
  for p in "$@"; do
    brew list --formula "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  [[ ${#missing[@]} -eq 0 ]] && {
    skip "brew: $*"
    return 0
  }
  run brew install "${missing[@]}" || fail "brew install ${missing[*]}"
}

apt_install() {
  local p missing=()
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  [[ ${#missing[@]} -eq 0 ]] && {
    skip "apt: all present"
    return 0
  }
  run sudo apt-get update && run sudo apt-get install -y "${missing[@]}" || fail "apt-get install ${missing[*]}"
}

step_system() {
  log "system packages"
  case "$os" in
    mac)
      # make and a C compiler (telescope-fzf-native, treesitter parsers) come from the Command Line Tools
      xcode-select -p >/dev/null 2>&1 || warn "Command Line Tools missing: run xcode-select --install"
      brew_install ripgrep fd xz # git and curl ship with macOS and the Command Line Tools
      ;;
    apt)
      apt_install make gcc unzip git curl ripgrep fd-find xclip \
        build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libncurses-dev \
        xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
      ;;
    *) warn "no package manager support for $(uname -s); install make, gcc, ripgrep, git and curl by hand" ;;
  esac
}

pyenv_bin() {
  if have pyenv; then
    command -v pyenv
  elif [[ -x "$PYENV_ROOT/bin/pyenv" ]]; then
    echo "$PYENV_ROOT/bin/pyenv"
  fi
}

step_pyenv() {
  log "pyenv"
  [[ -n "$(pyenv_bin)" ]] && {
    skip "pyenv ($(pyenv_bin))"
    return 0
  }
  if [[ "$os" == mac ]]; then
    brew_install pyenv
  else
    # Installs into $PYENV_ROOT; the shell rc needs `eval "$(pyenv init -)"` (rcfiles' .bashrc has it)
    run sh -c 'curl -fsSL https://pyenv.run | bash' || fail "pyenv install"
  fi
}

step_python() {
  log "python $PYTHON_VERSION + myenv"
  local pyenv venv="$PYENV_ROOT/versions/myenv"
  pyenv="$(pyenv_bin)"
  [[ -n "$pyenv" ]] || {
    fail "pyenv not found (run the pyenv step first)"
    return 1
  }
  run "$pyenv" install -s "$PYTHON_VERSION" || {
    fail "pyenv install $PYTHON_VERSION (build dependencies missing? run the system step)"
    return 1
  }
  # A plain venv inside versions/ is a pyenv version as far as pyenv is concerned, so the pyenv-virtualenv
  # plugin is not needed. An existing myenv (from pyenv-virtualenv or otherwise) is kept as it is.
  if [[ -x "$venv/bin/python" ]]; then
    skip "myenv ($venv)"
  else
    run "$PYENV_ROOT/versions/$PYTHON_VERSION/bin/python" -m venv "$venv" || {
      fail "create $venv"
      return 1
    }
  fi
  if [[ -x "$venv/bin/python" ]] && "$venv/bin/python" -c 'import pynvim' 2>/dev/null; then
    skip "pynvim"
  else
    run "$venv/bin/python" -m pip install --quiet --upgrade pip pynvim || fail "pip install pynvim"
  fi
}

# Newest installed nvm node at or above NODE_MAJOR, or nothing
nvm_node() {
  local d
  for d in "$NVM_DIR"/versions/node/v*; do
    [[ -x "$d/bin/node" ]] || continue
    local major="${d##*/v}"
    major="${major%%.*}"
    [[ "$major" -ge "$NODE_MAJOR" ]] && echo "$d/bin/node"
  done | sort -V | tail -1
}

step_node() {
  log "nvm + node $NODE_MAJOR"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    skip "nvm ($NVM_DIR)"
  else
    # PROFILE=/dev/null: the installer would otherwise append to ~/.bashrc, which may be a symlink into rcfiles.
    # The installer refuses a NVM_DIR that is set but missing, which is the normal state on a fresh machine
    # whose shell rc already exports it, so create it first.
    run mkdir -p "$NVM_DIR" && run sh -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | NVM_DIR='$NVM_DIR' PROFILE=/dev/null bash" || {
      fail "nvm install"
      return 1
    }
    log "add to your shell rc: export NVM_DIR=\"$NVM_DIR\"; . \"\$NVM_DIR/nvm.sh\""
  fi
  if [[ -n "$(nvm_node)" ]]; then
    skip "node $NODE_MAJOR+ ($(nvm_node))"
    return 0
  fi
  if [[ -n "$DRY_RUN" ]]; then
    run nvm install "$NODE_MAJOR"
    return 0
  fi
  # nvm is a shell function and is not written for `set -u`
  (
    set +u
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh" && nvm install "$NODE_MAJOR"
  ) || fail "nvm install $NODE_MAJOR"
}

# Version of the tree-sitter on PATH, or nothing
ts_version() {
  have tree-sitter && tree-sitter --version 2>/dev/null | awk '{print $2}'
}
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

step_treesitter() {
  log "tree-sitter CLI $TS_MIN_VERSION+"
  local v
  v="$(ts_version)"
  if [[ -n "$v" ]] && version_ge "$v" "$TS_MIN_VERSION"; then
    skip "tree-sitter $v ($(command -v tree-sitter))"
    return 0
  fi
  [[ -n "$v" ]] && warn "tree-sitter $v at $(command -v tree-sitter) is older than $TS_MIN_VERSION"
  if [[ "$os" == mac ]]; then
    brew_install tree-sitter-cli
    return
  fi
  # apt's tree-sitter-cli is missing or too old on current Ubuntu/Debian, so use the release binary
  local platform
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Linux/amd64) platform=linux-x64 ;;
    Linux/aarch64 | Linux/arm64) platform=linux-arm64 ;;
    Linux/armv7l | Linux/armv6l) platform=linux-arm ;;
    *)
      fail "no tree-sitter release for $(uname -s)/$(uname -m): https://github.com/tree-sitter/tree-sitter/releases"
      return 1
      ;;
  esac
  local url="https://github.com/tree-sitter/tree-sitter/releases/latest/download/tree-sitter-$platform.gz"
  if [[ -n "$DRY_RUN" ]]; then
    run curl -fL "$url" "| gunzip > $BIN_DIR/tree-sitter"
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  # Runs it before replacing anything, so a binary this machine's glibc cannot load leaves the old one in place
  if curl -fsSL "$url" | gunzip >"$tmp/tree-sitter" && chmod +x "$tmp/tree-sitter" && "$tmp/tree-sitter" --version >/dev/null 2>&1; then
    if mkdir -p "$BIN_DIR" && mv "$tmp/tree-sitter" "$BIN_DIR/tree-sitter"; then
      printf '    %s -> %s\n' "$("$BIN_DIR/tree-sitter" --version)" "$BIN_DIR/tree-sitter"
      [[ "$(command -v tree-sitter)" == "$BIN_DIR/tree-sitter" ]] || warn "put $BIN_DIR first in PATH (tree-sitter on PATH: $(command -v tree-sitter || echo none))"
    else
      fail "install tree-sitter into $BIN_DIR"
    fi
  else
    fail "download or run $url (glibc too old? build it with cargo install --locked tree-sitter-cli)"
  fi
  rm -rf "$tmp"
}

all_steps=(system pyenv python node treesitter)
steps=("$@")
[[ ${#steps[@]} -eq 0 ]] && steps=("${all_steps[@]}")
for s in "${steps[@]}"; do
  case "$s" in
    -h | --help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    system | pyenv | python | node | treesitter) ;;
    *)
      echo "Unknown step: $s (steps: ${all_steps[*]})" >&2
      exit 2
      ;;
  esac
done

[[ -n "$DRY_RUN" ]] && log "DRY_RUN=1: nothing will be changed"
for s in "${steps[@]}"; do
  "step_$s"
done

if [[ ${#failed[@]} -gt 0 ]]; then
  printf '\n%d step(s) failed:\n' "${#failed[@]}" >&2
  printf '  - %s\n' "${failed[@]}" >&2
  exit 1
fi
