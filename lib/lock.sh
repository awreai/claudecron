#!/usr/bin/env bash
# Copyright (c) 2026 The claudecron authors
#
# lib/lock.sh - single-runner mutual exclusion using a directory (mkdir is
# atomic on POSIX filesystems). No flock (unavailable on macOS bash 3.2).
#
# Lock dir: <CLAUDECRON_HOME>/lock/
#
# Acquire: mkdir the lock dir.
#   - success -> we hold it; install release trap; return 0.
#   - failure -> inspect age; if older than lock_stale_minutes, steal it
#     (log the steal) and retry once; otherwise another runner is active,
#     so log a quiet skip and exit 0 (NOT an error).
#
# Release: rmdir on trap EXIT INT TERM, only if we own it.
#
# Depends on lib/common.sh (paths, logging) and cfg_get from lib/config.sh.

if [ -n "${CLAUDECRON_LOCK_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDECRON_LOCK_SOURCED=1

# Tracks whether THIS process owns the lock (for the release trap).
CLAUDECRON_LOCK_OWNED=0

# lock__mtime_epoch <path> - mtime in epoch seconds; BSD stat vs GNU stat.
lock__mtime_epoch() {
  lm__path="$1"
  # BSD/macOS stat
  lm__out="$(stat -f %m "$lm__path" 2>/dev/null)"
  if [ -n "$lm__out" ]; then
    printf '%s\n' "$lm__out"
    unset lm__path lm__out
    return 0
  fi
  # GNU stat
  lm__out="$(stat -c %Y "$lm__path" 2>/dev/null)"
  if [ -n "$lm__out" ]; then
    printf '%s\n' "$lm__out"
    unset lm__path lm__out
    return 0
  fi
  unset lm__path lm__out
  return 1
}

# lock__now_epoch - epoch seconds; prefer due.sh's epoch_now if present.
lock__now_epoch() {
  if command -v epoch_now >/dev/null 2>&1; then
    epoch_now
  else
    date '+%s'
  fi
}

# lock_release - remove the lock dir if we own it. Safe to call repeatedly.
lock_release() {
  if [ "$CLAUDECRON_LOCK_OWNED" = "1" ]; then
    rmdir "$CLAUDECRON_LOCK_DIR" 2>/dev/null || rm -rf "$CLAUDECRON_LOCK_DIR" 2>/dev/null || true
    CLAUDECRON_LOCK_OWNED=0
    cc_log "released lock"
  fi
  return 0
}

# lock__install_trap - arm release on EXIT INT TERM.
lock__install_trap() {
  trap 'lock_release' EXIT
  trap 'lock_release; exit 130' INT
  trap 'lock_release; exit 143' TERM
}

# lock__try_mkdir - one attempt; returns 0 if acquired.
lock__try_mkdir() {
  mkdir "$CLAUDECRON_LOCK_DIR" 2>/dev/null
}

# ---------------------------------------------------------------------------
# lock_acquire
#   Returns 0 and arms the release trap when the lock is held by us.
#   When another live runner holds the lock, logs a quiet skip and exits 0
#   (the process should not proceed; a clean no-op is the desired outcome).
# ---------------------------------------------------------------------------
lock_acquire() {
  # Ensure the parent dir exists (lock dir itself must NOT pre-exist).
  mkdir -p "$(dirname "$CLAUDECRON_LOCK_DIR")" 2>/dev/null || true

  if lock__try_mkdir; then
    CLAUDECRON_LOCK_OWNED=1
    lock__install_trap
    printf '%s\n' "$$" > "$CLAUDECRON_LOCK_DIR/pid" 2>/dev/null || true
    cc_log "acquired lock"
    return 0
  fi

  # Could not acquire: examine staleness.
  la__stale_min="$(cfg_get lock_stale_minutes 30)"
  case "$la__stale_min" in
    ''|*[!0-9]* ) la__stale_min=30 ;;
  esac
  la__stale_sec=$(( la__stale_min * 60 ))

  la__mtime="$(lock__mtime_epoch "$CLAUDECRON_LOCK_DIR")"
  la__now="$(lock__now_epoch)"

  if [ -n "$la__mtime" ] && [ -n "$la__now" ]; then
    la__age=$(( la__now - la__mtime ))
    if [ "$la__age" -ge "$la__stale_sec" ]; then
      cc_log "stealing stale lock (age ${la__age}s >= ${la__stale_sec}s threshold)"
      rm -rf "$CLAUDECRON_LOCK_DIR" 2>/dev/null || true
      if lock__try_mkdir; then
        CLAUDECRON_LOCK_OWNED=1
        lock__install_trap
        printf '%s\n' "$$" > "$CLAUDECRON_LOCK_DIR/pid" 2>/dev/null || true
        cc_log "acquired lock after reclaiming stale lock"
        unset la__stale_min la__stale_sec la__mtime la__now la__age
        return 0
      fi
      cc_log "another runner reclaimed the lock first; skipping"
      unset la__stale_min la__stale_sec la__mtime la__now la__age
      exit 0
    fi
  fi

  cc_log "another runner holds the lock; skipping this run"
  unset la__stale_min la__stale_sec la__mtime la__now la__age
  exit 0
}

# loop_lock_acquire <id> - per-loop mutual exclusion. Returns 0 if acquired,
# 1 if another live process holds it (caller should skip this loop). Steals a
# stale per-loop lock (older than lock_stale_minutes) first. Never exits.
loop_lock_acquire() {
  lla__id="$1"
  lla__dir="$CLAUDECRON_LOCK_DIR/$lla__id"
  mkdir -p "$CLAUDECRON_LOCK_DIR" 2>/dev/null || true
  if mkdir "$lla__dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$lla__dir/pid" 2>/dev/null || true
    unset lla__id lla__dir
    return 0
  fi
  lla__stale_min="$(cfg_get lock_stale_minutes 30)"
  case "$lla__stale_min" in ''|*[!0-9]* ) lla__stale_min=30 ;; esac
  lla__stale_sec=$(( lla__stale_min * 60 ))
  lla__mtime="$(lock__mtime_epoch "$lla__dir")"
  lla__now="$(lock__now_epoch)"
  if [ -n "$lla__mtime" ] && [ -n "$lla__now" ]; then
    lla__age=$(( lla__now - lla__mtime ))
    if [ "$lla__age" -ge "$lla__stale_sec" ]; then
      cc_log "stealing stale loop lock for '$lla__id' (age ${lla__age}s)"
      rm -rf "$lla__dir" 2>/dev/null || true
      if mkdir "$lla__dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lla__dir/pid" 2>/dev/null || true
        unset lla__id lla__dir lla__stale_min lla__stale_sec lla__mtime lla__now lla__age
        return 0
      fi
    fi
  fi
  cc_log "loop '$lla__id' already running; skipping"
  unset lla__id lla__dir lla__stale_min lla__stale_sec lla__mtime lla__now lla__age
  return 1
}

# loop_lock_release <id> - release a per-loop lock.
loop_lock_release() {
  llr__dir="$CLAUDECRON_LOCK_DIR/$1"
  rmdir "$llr__dir" 2>/dev/null || rm -rf "$llr__dir" 2>/dev/null || true
  unset llr__dir
  return 0
}
