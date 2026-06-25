#!/usr/bin/env bash
# Copyright (c) 2026 The claudecron authors
#
# lib/state.sh - per-host run state for each loop.
#
# State file path: <CLAUDECRON_HOME>/state/<HOST>/<id>.json
#
# A state file is loop-owned: it may carry arbitrary cursor keys written by the
# loop's own prompt/backend. state_record_run therefore does a read-merge-write
# and only ever sets last_run / last_status / last_duration_s, leaving every
# other key untouched.
#
# Depends on lib/common.sh (cc_jq, paths, HOST, logging) and the iso/epoch
# helpers from lib/due.sh (epoch_now). If due.sh is not yet sourced we fall
# back to a local epoch reader.

if [ -n "${CLAUDECRON_STATE_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDECRON_STATE_SOURCED=1

# state_dir - per-host state directory; created on demand.
state_dir() {
  printf '%s/%s\n' "$CLAUDECRON_STATE_DIR" "$CLAUDECRON_HOST"
}

# state_path <id> - absolute path to the loop's state file (dir ensured).
state_path() {
  sp__id="$1"
  sp__dir="$(state_dir)"
  mkdir -p "$sp__dir" 2>/dev/null || true
  printf '%s/%s.json\n' "$sp__dir" "$sp__id"
  unset sp__id sp__dir
}

# state__epoch_now - epoch seconds; prefer due.sh's epoch_now if available.
state__epoch_now() {
  if command -v epoch_now >/dev/null 2>&1; then
    epoch_now
  else
    date '+%s'
  fi
}

# state__atomic_write <dest> - write stdin atomically.
state__atomic_write() {
  sw__dest="$1"
  sw__dir="$(dirname "$sw__dest")"
  mkdir -p "$sw__dir" 2>/dev/null || true
  sw__tmp="$sw__dest.tmp.$$"
  cat > "$sw__tmp" || { rm -f "$sw__tmp"; return 1; }
  mv -f "$sw__tmp" "$sw__dest" || { rm -f "$sw__tmp"; return 1; }
  unset sw__dest sw__dir sw__tmp
  return 0
}

# state_get <id> - print the loop's state JSON ({} if none).
state_get() {
  sg__path="$(state_path "$1")"
  if [ -f "$sg__path" ]; then
    cc_jq '.' "$sg__path" 2>/dev/null || printf '%s\n' '{}'
  else
    printf '%s\n' '{}'
  fi
  unset sg__path
}

# state_get_field <id> <key> [default] - print one scalar state field.
state_get_field() {
  sgf__id="$1"
  sgf__key="$2"
  sgf__def="${3:-}"
  sgf__val="$(state_get "$sgf__id" | cc_jq -r --arg k "$sgf__key" '.[$k] // empty' 2>/dev/null)"
  if [ -z "$sgf__val" ]; then
    printf '%s\n' "$sgf__def"
  else
    printf '%s\n' "$sgf__val"
  fi
  unset sgf__id sgf__key sgf__def sgf__val
}

# state_last_run_epoch <id> - print the last_run epoch (empty if never run).
# last_run is stored as an integer epoch second.
state_last_run_epoch() {
  state_get_field "$1" last_run ""
}

# ---------------------------------------------------------------------------
# state_record_run <id> <status> <duration_seconds>
#
# Read-merge-write: sets ONLY last_run (epoch now), last_status, and
# last_duration_s. All loop-owned cursor keys survive untouched.
# ---------------------------------------------------------------------------
state_record_run() {
  srr__id="$1"
  srr__status="$2"
  srr__dur="$3"
  srr__path="$(state_path "$srr__id")"
  srr__now="$(state__epoch_now)"

  # Normalize duration to an integer; default 0 on garbage.
  case "$srr__dur" in
    ''|*[!0-9]* ) srr__dur=0 ;;
  esac

  state_get "$srr__id" | cc_jq \
    --argjson now "$srr__now" \
    --arg status "$srr__status" \
    --argjson dur "$srr__dur" \
    '. + { last_run: $now, last_status: $status, last_duration_s: $dur }' \
    | state__atomic_write "$srr__path" || {
      cc_err "failed to record run state for '$srr__id'"
      unset srr__id srr__status srr__dur srr__path srr__now
      return 1
    }

  unset srr__id srr__status srr__dur srr__path srr__now
  return 0
}
