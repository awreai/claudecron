#!/usr/bin/env bash
# Copyright (c) 2026 The claudecron authors
#
# lib/common.sh - path resolution, logging, jq wrapper, data-tree creation.
#
# Sourcing this file has no side effects beyond defining functions and
# resolving CLAUDECRON_HOME plus the derived directory variables. It does
# NOT create directories (use cc_mkdirs for that) and does NOT run a backend.
#
# Portability: macOS /bin/bash 3.2 safe. No mapfile/readarray, no flock,
# no associative arrays. Array expansions are guarded for set -u.

# Guard against double-sourcing.
if [ -n "${CLAUDECRON_COMMON_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDECRON_COMMON_SOURCED=1

# ---------------------------------------------------------------------------
# libexec root: the directory tree that contains bin/ lib/ templates/ VERSION.
# This file lives in <libexec>/lib/common.sh, so the libexec root is two
# levels up from this file.
# ---------------------------------------------------------------------------
cc__this_file="${BASH_SOURCE[0]}"
cc__lib_dir="$(cd "$(dirname "$cc__this_file")" >/dev/null 2>&1 && pwd)"
CLAUDECRON_LIBEXEC="$(cd "$cc__lib_dir/.." >/dev/null 2>&1 && pwd)"
export CLAUDECRON_LIBEXEC
unset cc__this_file cc__lib_dir

# Allow callers/installers to pin the prefix explicitly.
CLAUDECRON_PREFIX="${CLAUDECRON_PREFIX:-$CLAUDECRON_LIBEXEC}"
export CLAUDECRON_PREFIX

# ---------------------------------------------------------------------------
# Version: read from <libexec>/VERSION if present.
# ---------------------------------------------------------------------------
if [ -z "${CLAUDECRON_VERSION:-}" ]; then
  if [ -r "$CLAUDECRON_LIBEXEC/VERSION" ]; then
    CLAUDECRON_VERSION="$(head -n 1 "$CLAUDECRON_LIBEXEC/VERSION" 2>/dev/null | tr -d ' \t\r\n')"
  fi
  CLAUDECRON_VERSION="${CLAUDECRON_VERSION:-0.0.0}"
fi
export CLAUDECRON_VERSION

# ---------------------------------------------------------------------------
# Resolve CLAUDECRON_HOME (user data root).
# Order: $CLAUDECRON_HOME -> $XDG_CONFIG_HOME/claudecron -> ~/.config/claudecron
# Fallback to ~/.claudecron only if HOME is set but ~/.config is unavailable.
# ---------------------------------------------------------------------------
cc__resolve_home() {
  if [ -n "${CLAUDECRON_HOME:-}" ]; then
    printf '%s\n' "$CLAUDECRON_HOME"
    return 0
  fi
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s/claudecron\n' "$XDG_CONFIG_HOME"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    printf '%s/.config/claudecron\n' "$HOME"
    return 0
  fi
  # Last-ditch fallback.
  printf '%s\n' "${HOME:-.}/.claudecron"
}

CLAUDECRON_HOME="$(cc__resolve_home)"
export CLAUDECRON_HOME

# cc_rehome - (re)compute all derived directory variables from the current
# CLAUDECRON_HOME. Called once at source time, and again by the CLI after it
# applies a --config override (which changes CLAUDECRON_HOME). Idempotent.
cc_rehome() {
  CLAUDECRON_HOME="$(cc__resolve_home)"
  CLAUDECRON_PROMPTS_DIR="$CLAUDECRON_HOME/prompts"
  CLAUDECRON_STATE_DIR="$CLAUDECRON_HOME/state"
  CLAUDECRON_LOGS_DIR="$CLAUDECRON_HOME/logs"
  CLAUDECRON_LOCK_DIR="$CLAUDECRON_HOME/lock"
  CLAUDECRON_REGISTRY="$CLAUDECRON_HOME/registry.json"
  CLAUDECRON_CONFIG="$CLAUDECRON_HOME/config.json"
  CLAUDECRON_RUNNER_LOG="$CLAUDECRON_LOGS_DIR/runner.log"
  export CLAUDECRON_HOME
  export CLAUDECRON_PROMPTS_DIR CLAUDECRON_STATE_DIR CLAUDECRON_LOGS_DIR
  export CLAUDECRON_LOCK_DIR CLAUDECRON_REGISTRY CLAUDECRON_CONFIG CLAUDECRON_RUNNER_LOG
}
cc_rehome

# ---------------------------------------------------------------------------
# Host (per-host state segregation): short hostname.
# ---------------------------------------------------------------------------
if [ -z "${CLAUDECRON_HOST:-}" ]; then
  CLAUDECRON_HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'localhost')"
  # Sanitize: strip anything that is not a safe filename char.
  CLAUDECRON_HOST="$(printf '%s' "$CLAUDECRON_HOST" | tr -c 'A-Za-z0-9._-' '-')"
  [ -n "$CLAUDECRON_HOST" ] || CLAUDECRON_HOST="localhost"
fi
export CLAUDECRON_HOST
HOST="$CLAUDECRON_HOST"
export HOST

# ---------------------------------------------------------------------------
# Logging.
# cc_log writes an ISO-ish timestamped line to stderr (human channel).
# cc_err writes to stderr with an ERROR tag.
# cc_die logs an error and exits non-zero.
# ---------------------------------------------------------------------------
cc_now_iso() {
  date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'
}

cc_log() {
  printf '%s [claudecron] %s\n' "$(cc_now_iso)" "$*" >&2
}

cc_err() {
  printf '%s [claudecron] ERROR: %s\n' "$(cc_now_iso)" "$*" >&2
}

cc_die() {
  cc_err "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# jq wrapper. Hard-fail with an install hint if jq is missing.
# Resolved once and cached in CLAUDECRON_JQ_BIN.
# ---------------------------------------------------------------------------
cc_jq() {
  if [ -z "${CLAUDECRON_JQ_BIN:-}" ]; then
    CLAUDECRON_JQ_BIN="$(command -v jq 2>/dev/null || true)"
    if [ -z "$CLAUDECRON_JQ_BIN" ]; then
      cc_err "jq is required but was not found on PATH."
      cc_err "Install it: macOS 'brew install jq'  |  Debian/Ubuntu 'apt-get install jq'"
      exit 127
    fi
  fi
  "$CLAUDECRON_JQ_BIN" "$@"
}

# ---------------------------------------------------------------------------
# cc_mkdirs - lazily create the data tree. Idempotent.
# ---------------------------------------------------------------------------
cc_mkdirs() {
  mkdir -p \
    "$CLAUDECRON_HOME" \
    "$CLAUDECRON_PROMPTS_DIR" \
    "$CLAUDECRON_STATE_DIR" \
    "$CLAUDECRON_STATE_DIR/$CLAUDECRON_HOST" \
    "$CLAUDECRON_LOGS_DIR" 2>/dev/null || {
    cc_err "failed to create data tree under $CLAUDECRON_HOME"
    return 1
  }
  return 0
}
