#!/bin/sh
# uninstall.sh - uninstaller for claudecron
#
# Copyright (c) 2026 The claudecron authors
# SPDX-License-Identifier: MIT
#
# Removes the scheduler registration first, then the entrypoint symlink and the
# staged program files. User config and state are preserved unless --purge is
# passed. Prints exactly what was removed and what was kept.
#
# Usage:
#   ./uninstall.sh            keep config/state
#   ./uninstall.sh --purge    also delete CLAUDECRON_HOME (config, state, logs)

set -eu

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help)
      printf 'Usage: uninstall.sh [--purge]\n'
      printf '  --purge   also delete CLAUDECRON_HOME (config, state, logs)\n'
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# --- layout (mirror installer) ------------------------------------------------
PREFIX="${CLAUDECRON_PREFIX:-$HOME/.local/share}"
LIBEXEC="$PREFIX/claudecron"
BIN_LINK="$HOME/.local/bin/claudecron"

# Resolve CLAUDECRON_HOME: $CLAUDECRON_HOME -> $XDG_CONFIG_HOME/claudecron -> ~/.config/claudecron
resolve_home() {
  if [ -n "${CLAUDECRON_HOME:-}" ]; then
    printf '%s\n' "$CLAUDECRON_HOME"
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s\n' "$XDG_CONFIG_HOME/claudecron"
  elif [ -d "$HOME/.config/claudecron" ]; then
    printf '%s\n' "$HOME/.config/claudecron"
  elif [ -d "$HOME/.claudecron" ]; then
    printf '%s\n' "$HOME/.claudecron"
  else
    printf '%s\n' "$HOME/.config/claudecron"
  fi
}
HOME_DIR="$(resolve_home)"

# --- 1. remove scheduler FIRST ------------------------------------------------
removed_scheduler=0
if [ -x "$BIN_LINK" ]; then
  info "Removing scheduler registration"
  if "$BIN_LINK" scheduler remove >/dev/null 2>&1; then
    removed_scheduler=1
  else
    warn "could not remove scheduler via 'claudecron scheduler remove' (continuing)"
  fi
elif command -v claudecron >/dev/null 2>&1; then
  info "Removing scheduler registration"
  if claudecron scheduler remove >/dev/null 2>&1; then
    removed_scheduler=1
  else
    warn "could not remove scheduler via 'claudecron scheduler remove' (continuing)"
  fi
else
  warn "claudecron binary not found; skipping scheduler removal"
fi

# --- 2. remove symlink --------------------------------------------------------
removed_link=0
if [ -L "$BIN_LINK" ] || [ -e "$BIN_LINK" ]; then
  rm -f "$BIN_LINK"
  removed_link=1
fi

# --- 3. remove libexec --------------------------------------------------------
removed_libexec=0
if [ -d "$LIBEXEC" ]; then
  rm -rf "$LIBEXEC"
  removed_libexec=1
fi

# --- 4. optionally purge config/state ----------------------------------------
purged_home=0
if [ "$PURGE" -eq 1 ]; then
  if [ -d "$HOME_DIR" ]; then
    rm -rf "$HOME_DIR"
    purged_home=1
  fi
fi

# --- report -------------------------------------------------------------------
printf '\n'
info "claudecron uninstall summary"
info "----------------------------"

if [ "$removed_scheduler" -eq 1 ]; then
  info "removed:  scheduler registration (dev.claudecron.runner)"
else
  info "skipped:  scheduler registration (not present or not removable)"
fi

if [ "$removed_link" -eq 1 ]; then
  info "removed:  symlink ${BIN_LINK}"
else
  info "skipped:  symlink ${BIN_LINK} (not present)"
fi

if [ "$removed_libexec" -eq 1 ]; then
  info "removed:  program files ${LIBEXEC}"
else
  info "skipped:  program files ${LIBEXEC} (not present)"
fi

if [ "$PURGE" -eq 1 ]; then
  if [ "$purged_home" -eq 1 ]; then
    info "removed:  config and state ${HOME_DIR}"
  else
    info "skipped:  config and state ${HOME_DIR} (not present)"
  fi
else
  info "kept:     config and state ${HOME_DIR}"
  info "          (re-run with --purge to delete it)"
fi

printf '\n'
info "Done."
