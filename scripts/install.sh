#!/bin/sh
# One-line installer for sqlode. Downloads the released escript into a
# user-writable directory and verifies it runs.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/nao1215/sqlode/main/scripts/install.sh | sh
#
# Environment overrides:
#   SQLODE_VERSION    - tag to install (default: latest). Example: v0.1.0
#   SQLODE_INSTALL_DIR - directory to install into (default: $HOME/.local/bin)

set -eu

REPO="nao1215/sqlode"
BIN_NAME="sqlode"
VERSION="${SQLODE_VERSION:-latest}"
INSTALL_DIR="${SQLODE_INSTALL_DIR:-$HOME/.local/bin}"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need_cmd curl
need_cmd uname

# sqlode ships as an escript, which is a portable Erlang archive. It needs
# `escript` (part of the Erlang/OTP runtime) on the PATH at run time.
detect_distro_id() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    (. /etc/os-release; printf '%s' "${ID:-}")
  fi
}

check_erlang() {
  if command -v escript >/dev/null 2>&1; then
    return 0
  fi

  warn "Erlang/OTP runtime not found on PATH."
  os="$(uname -s)"
  case "$os" in
    Linux)
      case "$(detect_distro_id)" in
        ubuntu|debian) warn "install it with: sudo apt-get install -y erlang" ;;
        fedora|rhel|centos) warn "install it with: sudo dnf install -y erlang" ;;
        arch|manjaro) warn "install it with: sudo pacman -S --noconfirm erlang" ;;
        alpine) warn "install it with: sudo apk add erlang" ;;
        *) warn "install Erlang/OTP via your distribution's package manager" ;;
      esac
      ;;
    Darwin)
      warn "install it with: brew install erlang"
      ;;
    *)
      warn "see https://www.erlang.org/downloads for install options"
      ;;
  esac
  warn "sqlode will still be downloaded, but you must install Erlang/OTP before running it."
}

resolve_version() {
  if [ "$VERSION" = "latest" ]; then
    url="https://api.github.com/repos/${REPO}/releases/latest"
    tag="$(curl -fsSL "$url" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
    if [ -z "$tag" ]; then
      die "could not determine latest release tag. Set SQLODE_VERSION=vX.Y.Z to pin a version."
    fi
    VERSION="$tag"
  fi
}

download() {
  url="https://github.com/${REPO}/releases/download/${VERSION}/${BIN_NAME}"
  info "downloading ${BIN_NAME} ${VERSION} from ${url}"
  tmp="$(mktemp -t sqlode.XXXXXX)"
  if ! curl -fsSL -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "failed to download ${url}. Check SQLODE_VERSION or visit https://github.com/${REPO}/releases."
  fi
  DOWNLOAD="$tmp"
}

install_bin() {
  mkdir -p "$INSTALL_DIR"
  dest="$INSTALL_DIR/$BIN_NAME"
  mv "$DOWNLOAD" "$dest"
  chmod +x "$dest"
  INSTALLED="$dest"
}

verify() {
  if ! command -v escript >/dev/null 2>&1; then
    info "skipping run check (Erlang/OTP not on PATH yet)"
    return 0
  fi
  if ! "$INSTALLED" --help >/dev/null 2>&1; then
    warn "${INSTALLED} was installed but --help failed. Inspect manually."
  fi
}

path_hint() {
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
      warn "$INSTALL_DIR is not on your PATH."
      warn "add it to your shell config, e.g. for bash/zsh:"
      warn "  export PATH=\"$INSTALL_DIR:\$PATH\""
      ;;
  esac
}

main() {
  check_erlang
  resolve_version
  download
  install_bin
  verify
  path_hint
  info "installed ${BIN_NAME} ${VERSION} at ${INSTALLED}"
}

main "$@"
