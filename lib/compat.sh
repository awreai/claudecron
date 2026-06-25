#!/usr/bin/env bash
# Copyright (c) 2026 The claudecron authors
#
# lib/compat.sh - thin shim/adapter layer.
#
# The CLI entrypoint (bin/claudecron) and the library modules (lib/*.sh) were
# written against slightly different naming conventions. The CLI calls a set of
# function names that the libs never define; this file maps each of those names
# onto the real lib function (or exported variable), adapting arguments where
# the calling conventions differ.
#
# This file MUST be sourced AFTER common.sh, config.sh, state.sh, lock.sh,
# due.sh, backend.sh, runner.sh, and scheduler.sh, so every real function and
# every CLAUDECRON_* variable is already defined.
#
# Portability: macOS /bin/bash 3.2 safe. No mapfile/readarray, no flock, no
# associative arrays. Array expansions are guarded for set -u.

# Guard against double-sourcing.
if [ -n "${CLAUDECRON_COMPAT_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDECRON_COMPAT_SOURCED=1

# ---------------------------------------------------------------------------
# 1. cc_hostname_s - short hostname. common.sh resolves $CLAUDECRON_HOST.
# ---------------------------------------------------------------------------
cc_hostname_s() {
  printf '%s\n' "${CLAUDECRON_HOST:-localhost}"
}

# ---------------------------------------------------------------------------
# 2. cc_run_pass - a bare due pass over the whole registry. The lib entry is
#    cc_run(); its full-registry pass is triggered by --wake (runner.sh).
# ---------------------------------------------------------------------------
cc_run_pass() {
  cc_run --wake ${@+"$@"}
}

# ---------------------------------------------------------------------------
# 3. cfg_init_defaults - write default config without clobbering. config.sh
#    provides config_ensure() which is exactly this (idempotent).
# ---------------------------------------------------------------------------
cfg_init_defaults() {
  config_ensure ${@+"$@"}
}

# ---------------------------------------------------------------------------
# 4. cfg_path - print the config.json path. common.sh exports CLAUDECRON_CONFIG.
# ---------------------------------------------------------------------------
cfg_path() {
  printf '%s\n' "$CLAUDECRON_CONFIG"
}

# ---------------------------------------------------------------------------
# 5. loop_registry_init - create registry.json. config.sh has registry_ensure().
# ---------------------------------------------------------------------------
loop_registry_init() {
  registry_ensure ${@+"$@"}
}

# ---------------------------------------------------------------------------
# 6. loop_registry_path - print the registry.json path. common.sh exports
#    CLAUDECRON_REGISTRY.
# ---------------------------------------------------------------------------
loop_registry_path() {
  printf '%s\n' "$CLAUDECRON_REGISTRY"
}

# ---------------------------------------------------------------------------
# 7. lock_is_stale - return 0 (true) if the lock dir exists AND its age exceeds
#    lock_stale_minutes, else 1. lock.sh holds the lock at $CLAUDECRON_LOCK_DIR
#    and provides lock__mtime_epoch and lock__now_epoch.
# ---------------------------------------------------------------------------
lock_is_stale() {
  [ -d "$CLAUDECRON_LOCK_DIR" ] || return 1

  lis__stale_min="$(cfg_get lock_stale_minutes 30)"
  case "$lis__stale_min" in
    ''|*[!0-9]* ) lis__stale_min=30 ;;
  esac
  lis__stale_sec=$(( lis__stale_min * 60 ))

  lis__mtime="$(lock__mtime_epoch "$CLAUDECRON_LOCK_DIR")"
  lis__now="$(lock__now_epoch)"

  if [ -z "$lis__mtime" ] || [ -z "$lis__now" ]; then
    unset lis__stale_min lis__stale_sec lis__mtime lis__now
    return 1
  fi

  lis__age=$(( lis__now - lis__mtime ))
  if [ "$lis__age" -ge "$lis__stale_sec" ]; then
    unset lis__stale_min lis__stale_sec lis__mtime lis__now lis__age
    return 0
  fi
  unset lis__stale_min lis__stale_sec lis__mtime lis__now lis__age
  return 1
}

# ---------------------------------------------------------------------------
# 8-13. scheduler verbs map onto cc_install / cc_uninstall / cc_verify.
# ---------------------------------------------------------------------------
scheduler_install() { cc_install ${@+"$@"}; }
scheduler_remove()  { cc_uninstall ${@+"$@"}; }
scheduler_enable()  { cc_install ${@+"$@"}; }
scheduler_disable() { cc_uninstall ${@+"$@"}; }
scheduler_is_loaded() { cc_verify ${@+"$@"}; }

scheduler_status() {
  ss__type="$(detect_scheduler 2>/dev/null || printf 'none')"
  printf 'scheduler: %s\n' "$ss__type"
  if cc_verify "$ss__type" >/dev/null 2>&1; then
    printf 'loaded: yes\n'
  else
    printf 'loaded: no\n'
  fi
  unset ss__type
  return 0
}

scheduler_last_wake() {
  if [ -n "${CLAUDECRON_RUNNER_LOG:-}" ] && [ -f "$CLAUDECRON_RUNNER_LOG" ]; then
    tail -n 1 "$CLAUDECRON_RUNNER_LOG" 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 15. state_get <id> <field> - the CLI calls state_get with a FIELD name and
#     expects that field's value (or empty if absent). The lib's state_get
#     ignores the second arg and prints the whole JSON. This override honors the
#     field argument. With no field given, falls back to the whole object.
# ---------------------------------------------------------------------------
state_get() {
  sg__id="$1"
  sg__field="${2:-}"
  sg__path="$(state_path "$sg__id")"
  if [ -n "$sg__field" ]; then
    # Field requested: print the value, or empty if file/field absent.
    if [ -f "$sg__path" ]; then
      cc_jq -r --arg f "$sg__field" '.[$f] // empty' "$sg__path" 2>/dev/null || true
    fi
  else
    # No field: print the whole object, defaulting to {} so callers that pipe
    # this into a jq merge (e.g. state_record_run) always get valid JSON.
    if [ -f "$sg__path" ]; then
      cc_jq '.' "$sg__path" 2>/dev/null || printf '%s\n' '{}'
    else
      printf '%s\n' '{}'
    fi
  fi
  unset sg__id sg__field sg__path
}

# ---------------------------------------------------------------------------
# 16. is_due <id> - the CLI calls is_due with a single loop ID and expects a
#     0/1 due verdict. The lib's is_due takes (last_run_epoch, interval_minutes).
#     This override looks up the loop's last_run + interval and delegates to the
#     lib via its real name. The lib name is captured once so the override does
#     not recurse. The runner keeps calling the 2-arg form before this file is
#     sourced (it is sourced last only into the CLI), so the runner is unaffected.
# ---------------------------------------------------------------------------
# Preserve the lib's two-arg implementation under a stable alias.
eval "$(declare -f is_due | sed '1s/^is_due/cc__is_due_epoch/')"
is_due() {
  # One numeric-or-empty arg that is not a known loop id -> treat as the
  # original (epoch, interval) contract for any internal caller.
  if [ "$#" -ge 2 ]; then
    cc__is_due_epoch "$@"
    return $?
  fi
   id__id="$1"
  if ! loop_exists "$id__id" 2>/dev/null; then
    # Fall back to the epoch contract (e.g. an epoch passed as a single arg).
    cc__is_due_epoch "$id__id" ""
    return $?
  fi
  id__entry="$(loop_get "$id__id" 2>/dev/null)"
  id__interval="$(printf '%s' "$id__entry" | cc_jq -r '.interval_minutes // 0' 2>/dev/null)"
  id__last="$(state_get "$id__id" last_run)"
  unset id__entry
  cc__is_due_epoch "$id__last" "$id__interval"
}

# ---------------------------------------------------------------------------
# 14. loop_upsert <id> - the CLI builds a complete loop JSON object and pipes
#     it on STDIN, passing the id as a positional arg. The lib's own
#     loop_upsert takes flags instead; this stdin-JSON form matches what the
#     CLI actually calls (two call sites: 'add' and enable/disable toggle).
#     Replaces any existing entry with the same id, else appends. Defined here
#     (sourced last) so it overrides the lib version for the CLI's contract.
# ---------------------------------------------------------------------------
loop_upsert() {
  lu__id="$1"
  validate_id "$lu__id" || return 1
  registry_ensure || return 1
  lu__obj="$(cat)"
  # Validate stdin is a JSON object.
  printf '%s' "$lu__obj" | cc_jq -e 'type == "object"' >/dev/null 2>&1 || {
    cc_err "loop_upsert: stdin was not a JSON object"
    unset lu__id lu__obj
    return 1
  }
  registry_read \
    | cc_jq --arg id "$lu__id" --argjson obj "$lu__obj" \
        '.loops = ((.loops | map(select(.id != $id))) + [$obj])' \
    | cc__atomic_write_stdin "$CLAUDECRON_REGISTRY" || { unset lu__id lu__obj; return 1; }
  unset lu__id lu__obj
  return 0
}
