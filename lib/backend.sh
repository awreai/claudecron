#!/usr/bin/env bash
# Copyright (c) 2026 The claudecron authors
#
# lib/backend.sh - resolve backend binaries and execute them per the binding
# invocation contract.
#
# Invocation contract:
#   claude: "$BIN" -p "$PROMPT" --allowedTools "$TOOLS" --add-dir "$CWD" \
#           [--add-dir D]... --output-format text
#   codex:  "$BIN" exec "$PROMPT" --cd "$CWD" --sandbox workspace-write \
#           --ask-for-approval never
#
# Test seam: if CLAUDECRON_TEST_BACKEND_CMD is set, that command is run
# INSTEAD of any real backend (token-free smoke tests). The prompt is passed
# on stdin and as $1; cwd is exported as CLAUDECRON_TEST_CWD.
#
# Depends on lib/common.sh (logging) and cfg_get from lib/config.sh.

if [ -n "${CLAUDECRON_BACKEND_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDECRON_BACKEND_SOURCED=1

# backend__login_shell_lookup <name> - last-resort resolution via an
# interactive-login shell PATH (catches GUI launchd contexts with a sparse
# PATH). Prints the resolved path or nothing.
backend__login_shell_lookup() {
  bls__name="$1"
  bls__shell="${SHELL:-/bin/bash}"
  bls__out="$("$bls__shell" -l -c "command -v $bls__name" 2>/dev/null | head -n 1)"
  if [ -n "$bls__out" ] && [ -x "$bls__out" ]; then
    printf '%s\n' "$bls__out"
  fi
  unset bls__name bls__shell bls__out
}

# ---------------------------------------------------------------------------
# resolve_backend_bin <claude|codex>
#   Resolution order:
#     1. pinned path from config (claude_bin / codex_bin) if set + executable
#     2. command -v <name>
#     3. login-shell PATH lookup
#   Prints the absolute binary path on success.
#   On failure prints a hint to stderr and returns 127.
# ---------------------------------------------------------------------------
resolve_backend_bin() {
  rbb__backend="$1"
  rbb__name=""
  rbb__cfg_key=""

  case "$rbb__backend" in
    claude ) rbb__name="claude"; rbb__cfg_key="claude_bin" ;;
    codex )  rbb__name="codex";  rbb__cfg_key="codex_bin" ;;
    * )
      cc_err "unknown backend '$rbb__backend' (expected: claude or codex)"
      unset rbb__backend rbb__name rbb__cfg_key
      return 127
      ;;
  esac

  # 1) pinned in config
  rbb__pinned="$(cfg_get "$rbb__cfg_key" "")"
  if [ -n "$rbb__pinned" ] && [ -x "$rbb__pinned" ]; then
    printf '%s\n' "$rbb__pinned"
    unset rbb__backend rbb__name rbb__cfg_key rbb__pinned
    return 0
  fi

  # 2) command -v
  rbb__found="$(command -v "$rbb__name" 2>/dev/null || true)"
  if [ -n "$rbb__found" ]; then
    printf '%s\n' "$rbb__found"
    unset rbb__backend rbb__name rbb__cfg_key rbb__pinned rbb__found
    return 0
  fi

  # 3) login-shell lookup
  rbb__found="$(backend__login_shell_lookup "$rbb__name")"
  if [ -n "$rbb__found" ]; then
    printf '%s\n' "$rbb__found"
    unset rbb__backend rbb__name rbb__cfg_key rbb__pinned rbb__found
    return 0
  fi

  cc_err "backend '$rbb__backend' binary ('$rbb__name') not found on PATH."
  cc_err "Install it, or pin its path in config.json ('$rbb__cfg_key')."
  unset rbb__backend rbb__name rbb__cfg_key rbb__pinned rbb__found
  return 127
}

# ---------------------------------------------------------------------------
# cc_backend_exec <backend> <prompt> <tools> <cwd> [add_dir...]
#   Builds and runs the binding invocation for the chosen backend.
#   The test seam (CLAUDECRON_TEST_BACKEND_CMD) preempts everything.
#   Returns the backend's exit status.
# ---------------------------------------------------------------------------
cc_backend_exec() {
  cbe__backend="$1"
  cbe__prompt="$2"
  cbe__tools="$3"
  cbe__cwd="$4"
  shift 4
  # Remaining positional args are add-dirs.

  # Test seam: run the provided command instead of a real backend.
  if [ -n "${CLAUDECRON_TEST_BACKEND_CMD:-}" ]; then
    cc_log "backend test seam active (CLAUDECRON_TEST_BACKEND_CMD)"
    CLAUDECRON_TEST_CWD="$cbe__cwd" \
    CLAUDECRON_TEST_BACKEND="$cbe__backend" \
    CLAUDECRON_TEST_TOOLS="$cbe__tools" \
      printf '%s' "$cbe__prompt" | CLAUDECRON_TEST_CWD="$cbe__cwd" sh -c "$CLAUDECRON_TEST_BACKEND_CMD" -- "$cbe__prompt"
    return $?
  fi

  cbe__bin="$(resolve_backend_bin "$cbe__backend")" || return 127

  # At this point "$@" holds the extra add-dir paths (the first four fixed args
  # were shifted off). We must NOT string-join the prompt (it is large, multi-
  # line, arbitrary): it stays a single positional parameter throughout. We
  # rebuild argv using the positional parameters only - bash 3.2 safe, no arrays.
  case "$cbe__backend" in
    claude )
      # Interleave "--add-dir <dir>" before each extra dir, preserving them as
      # real positional params. Rotate the current "$@" (the extra dirs) into a
      # new "$@" that is: <each dir prefixed by --add-dir>.
      cbe__ndirs="$#"
      cbe__i=0
      while [ "$cbe__i" -lt "$cbe__ndirs" ]; do
        cbe__d="$1"; shift
        if [ -n "$cbe__d" ]; then
          set -- "$@" --add-dir "$cbe__d"
        fi
        cbe__i=$(( cbe__i + 1 ))
      done
      unset cbe__ndirs cbe__i cbe__d
      # Now "$@" = (--add-dir D1 --add-dir D2 ...). Prepend the fixed claude
      # flags and run, with cwd as the primary --add-dir.
      ( cd "$cbe__cwd" 2>/dev/null || { cc_err "cwd missing: $cbe__cwd"; exit 3; }
        exec "$cbe__bin" -p "$cbe__prompt" \
          --allowedTools "$cbe__tools" \
          --add-dir "$cbe__cwd" \
          ${@+"$@"} \
          --output-format text
      )
      return $?
      ;;
    codex )
      ( cd "$cbe__cwd" 2>/dev/null || { cc_err "cwd missing: $cbe__cwd"; exit 3; }
        exec "$cbe__bin" exec "$cbe__prompt" \
          --cd "$cbe__cwd" \
          --sandbox workspace-write \
          --ask-for-approval never
      )
      return $?
      ;;
    * )
      cc_err "cc_backend_exec: unknown backend '$cbe__backend'"
      return 2
      ;;
  esac
}
