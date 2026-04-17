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

DOWNLOAD=""

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Clean up any half-downloaded temp file on early exit (ctrl-C, mkdir/mv
# failure, etc). install_bin clears DOWNLOAD after a successful move so the
# trap becomes a no-op.
cleanup() {
  [ -n "$DOWNLOAD" ] && [ -e "$DOWNLOAD" ] && rm -f "$DOWNLOAD"
}
trap cleanup EXIT INT HUP TERM

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
  [ "$VERSION" = "latest" ] || return 0

  # Prefer the JSON API because it gives a clean tag name, but it is rate
  # limited to 60 req/h for unauthenticated clients. Fall back to parsing
  # the Location header from /releases/latest, which is not subject to the
  # same limit.
  api_url="https://api.github.com/repos/${REPO}/releases/latest"
  tag="$(curl -fsSL "$api_url" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"

  if [ -z "$tag" ]; then
    redirect_url="https://github.com/${REPO}/releases/latest"
    tag="$(curl -fsSI "$redirect_url" \
      | sed -n 's/^[Ll]ocation: .*\/releases\/tag\/\([^[:space:]]*\).*/\1/p' \
      | tr -d '\r' \
      | tail -n1)"
  fi

  if [ -z "$tag" ]; then
    die "could not determine latest release tag (GitHub API rate limit or no releases yet). Set SQLODE_VERSION=vX.Y.Z to pin a version."
  fi
  VERSION="$tag"
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
  # Detect non-writable targets up front so the user sees an actionable
  # hint instead of a raw `mv: Permission denied` from `set -e`.
  if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
    die "cannot create $INSTALL_DIR. Re-run with sudo (e.g. 'sudo SQLODE_INSTALL_DIR=$INSTALL_DIR sh') or pick a user-writable path like \$HOME/.local/bin."
  fi
  if [ ! -w "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR is not writable. Re-run with sudo (e.g. 'sudo SQLODE_INSTALL_DIR=$INSTALL_DIR sh') or pick a user-writable path like \$HOME/.local/bin."
  fi

  dest="$INSTALL_DIR/$BIN_NAME"
  mv "$DOWNLOAD" "$dest"
  chmod +x "$dest"
  INSTALLED="$dest"
  # Successful move: the temp file no longer exists, so clear the trap
  # state to avoid a stray `rm -f` on EXIT.
  DOWNLOAD=""
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
