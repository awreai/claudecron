#!/bin/sh
# install.sh - installer for claudecron
#
# Copyright (c) 2026 The claudecron authors
# SPDX-License-Identifier: MIT
#
# Downloads a pinned release of claudecron, verifies its checksum, stages it
# into ~/.local/share/claudecron, symlinks the entrypoint into ~/.local/bin,
# and scaffolds user config. No sudo. Everything lives under $HOME.
#
# Pin the version:   CLAUDECRON_VERSION=0.1.0 ./install.sh
# Auto-register the scheduler (opt-in):  CLAUDECRON_INIT_SCHEDULER=1 ./install.sh
# Override install prefix (libexec parent default ~/.local/share):
#   CLAUDECRON_PREFIX=/some/dir ./install.sh

set -eu

# --- pinned version -----------------------------------------------------------
# Baked default; never tracks main. Env override wins.
DEFAULT_VERSION="0.1.0"
CLAUDECRON_VERSION="${CLAUDECRON_VERSION:-$DEFAULT_VERSION}"
VER="$CLAUDECRON_VERSION"

# --- layout -------------------------------------------------------------------
# libexec parent (program files live here under /claudecron)
PREFIX="${CLAUDECRON_PREFIX:-$HOME/.local/share}"
LIBEXEC="$PREFIX/claudecron"
BIN_DIR="$HOME/.local/bin"
BIN_LINK="$BIN_DIR/claudecron"

TARBALL="claudecron-${VER}.tar.gz"
BASE_URL="https://github.com/awreai/claudecron/releases/download/v${VER}"
TARBALL_URL="${BASE_URL}/${TARBALL}"
SHA_URL="${TARBALL_URL}.sha256"

# --- logging helpers ----------------------------------------------------------
info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
err()  { printf 'error: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- dependency checks (hard stop, never auto-install) ------------------------

platform() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      echo other ;;
  esac
}

install_hint() {
  # $1 = tool name
  case "$(platform)" in
    macos) printf '  brew install %s\n' "$1" ;;
    linux)
      printf '  Debian/Ubuntu:  sudo apt-get install -y %s\n' "$1"
      printf '  Fedora:         sudo dnf install -y %s\n' "$1"
      printf '  Arch:           sudo pacman -S %s\n' "$1"
      ;;
    *) printf '  install %s with your platform package manager\n' "$1" ;;
  esac
}

require_bash() {
  bash_bin="$(command -v bash 2>/dev/null || true)"
  if [ -z "$bash_bin" ]; then
    err "bash is required but was not found on PATH."
    install_hint bash >&2
    exit 1
  fi
  # Need bash >= 3.2. Read major.minor from BASH_VERSINFO.
  major="$("$bash_bin" -c 'echo ${BASH_VERSINFO[0]:-0}' 2>/dev/null || echo 0)"
  minor="$("$bash_bin" -c 'echo ${BASH_VERSINFO[1]:-0}' 2>/dev/null || echo 0)"
  case "$major" in *[!0-9]*|'') major=0 ;; esac
  case "$minor" in *[!0-9]*|'') minor=0 ;; esac
  if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 2 ]; }; then
    die "bash >= 3.2 required, found ${major}.${minor} at ${bash_bin}"
  fi
  info "Found bash ${major}.${minor} at ${bash_bin}"
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    err "jq is required but was not found on PATH."
    info "Install it, then re-run this installer:" >&2
    install_hint jq >&2
    exit 1
  fi
  info "Found jq at $(command -v jq)"
}

# --- download + verify helpers ------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

download() {
  # download URL DEST
  _url="$1"; _dest="$2"
  if have curl; then
    curl -fsSL "$_url" -o "$_dest"
  elif have wget; then
    wget -q "$_url" -O "$_dest"
  else
    die "neither curl nor wget is available to download ${_url}"
  fi
}

sha256_of() {
  # prints the hex digest of file $1
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "no sha256 tool found (need sha256sum or shasum)"
  fi
}

verify_checksum() {
  # verify_checksum TARBALL SHA_FILE
  _tar="$1"; _shafile="$2"
  # The .sha256 file may be in 'HEX  filename' form or just HEX.
  _expected="$(awk '{print $1}' "$_shafile" | head -n 1)"
  [ -n "$_expected" ] || die "could not read expected checksum from ${_shafile}"
  _actual="$(sha256_of "$_tar")"
  if [ "$_expected" != "$_actual" ]; then
    err "checksum mismatch for ${_tar}"
    err "  expected: ${_expected}"
    err "  actual:   ${_actual}"
    die "aborting before extraction"
  fi
  info "Checksum verified: ${_actual}"
}

# --- staging ------------------------------------------------------------------

stage_tree() {
  # stage_tree SRC_DIR
  # SRC_DIR must contain bin/ lib/ templates/ and (ideally) VERSION.
  _src="$1"
  [ -d "$_src/bin" ] || die "staging source missing bin/ at ${_src}"
  [ -d "$_src/lib" ] || die "staging source missing lib/ at ${_src}"
  [ -d "$_src/templates" ] || die "staging source missing templates/ at ${_src}"

  # Idempotent: clear then copy.
  rm -rf "$LIBEXEC"
  mkdir -p "$LIBEXEC"
  cp -R "$_src/bin" "$LIBEXEC/bin"
  cp -R "$_src/lib" "$LIBEXEC/lib"
  cp -R "$_src/templates" "$LIBEXEC/templates"

  if [ -f "$_src/VERSION" ]; then
    cp "$_src/VERSION" "$LIBEXEC/VERSION"
  else
    printf '%s\n' "$VER" > "$LIBEXEC/VERSION"
  fi

  chmod 0755 "$LIBEXEC/bin/claudecron" 2>/dev/null || true
  info "Staged claudecron into ${LIBEXEC}"
}

stage_from_download() {
  _work="$(mktemp -d "${TMPDIR:-/tmp}/claudecron-install.XXXXXX")" || die "could not create temp dir"
  # best-effort cleanup
  trap 'rm -rf "$_work"' EXIT INT TERM

  info "Downloading ${TARBALL_URL}"
  download "$TARBALL_URL" "$_work/$TARBALL"
  info "Downloading ${SHA_URL}"
  download "$SHA_URL" "$_work/$TARBALL.sha256"

  # Verify BEFORE extracting.
  verify_checksum "$_work/$TARBALL" "$_work/$TARBALL.sha256"

  info "Extracting ${TARBALL}"
  mkdir -p "$_work/unpacked"
  tar -xzf "$_work/$TARBALL" -C "$_work/unpacked"

  # Tarball may unpack into a single top-level dir or directly into place.
  _src="$_work/unpacked"
  if [ ! -d "$_src/bin" ]; then
    # find the directory that contains bin/
    for d in "$_work/unpacked"/*; do
      if [ -d "$d/bin" ]; then
        _src="$d"
        break
      fi
    done
  fi
  stage_tree "$_src"

  rm -rf "$_work"
  trap - EXIT INT TERM
}

# --- symlink ------------------------------------------------------------------

link_bin() {
  mkdir -p "$BIN_DIR"
  ln -sf "$LIBEXEC/bin/claudecron" "$BIN_LINK"
  info "Linked ${BIN_LINK} -> ${LIBEXEC}/bin/claudecron"

  # Warn if BIN_DIR is not on PATH.
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) : ;;
    *)
      warn "${BIN_DIR} is not on your PATH."
      printf '  Add this to your shell profile:\n' >&2
      printf '    export PATH="%s:$PATH"\n' "$BIN_DIR" >&2
      ;;
  esac
}

# --- scaffold config ----------------------------------------------------------

scaffold_config() {
  # 'claudecron init --no-scheduler' must never clobber existing config.
  if [ "${CLAUDECRON_INIT_SCHEDULER:-0}" = "1" ]; then
    info "Initializing config and registering scheduler"
    "$BIN_LINK" init || warn "claudecron init returned non-zero"
  else
    info "Initializing config (scheduler not registered)"
    "$BIN_LINK" init --no-scheduler || warn "claudecron init --no-scheduler returned non-zero"
    printf '\n'
    info "Scheduler was not registered. To enable scheduled runs, run:"
    info "    claudecron scheduler install"
  fi
}

# --- main ---------------------------------------------------------------------

main() {
  info "claudecron installer (version ${VER})"

  require_bash
  require_jq

  # SAFE local-dir fallback: if run from a checkout that already has a built
  # tree (./bin/claudecron), stage from there instead of downloading. Lets the
  # installer be exercised offline / in tests with no network and no real release.
  _self_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
  if [ -x "$_self_dir/bin/claudecron" ] && [ -d "$_self_dir/lib" ] && [ -d "$_self_dir/templates" ]; then
    info "Local checkout detected at ${_self_dir}; staging from there (offline mode)"
    stage_tree "$_self_dir"
  else
    stage_from_download
  fi

  link_bin
  scaffold_config

  printf '\n'
  info "claudecron ${VER} installed."
  info "Try: claudecron doctor"
}

main "$@"
