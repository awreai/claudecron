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

# lock_release - remove the lock dir if we still own it. Safe to call
# repeatedly. Guards against deleting a lock that another runner has since
# taken over: if the pid recorded in the lock is no longer ours, we stole
# nothing to release, so we leave it alone.
lock_release() {
  if [ "$CLAUDECRON_LOCK_OWNED" = "1" ]; then
    lr__holder="$(cat "$CLAUDECRON_LOCK_DIR/pid" 2>/dev/null | tr -dc '0-9')"
    if [ -n "$lr__holder" ] && [ "$lr__holder" != "$$" ]; then
      # Someone else owns it now; do not remove their lock.
      CLAUDECRON_LOCK_OWNED=0
      cc_log "lock now held by pid $lr__holder, not releasing"
      unset lr__holder
      return 0
    fi
    rmdir "$CLAUDECRON_LOCK_DIR" 2>/dev/null || rm -rf "$CLAUDECRON_LOCK_DIR" 2>/dev/null || true
    CLAUDECRON_LOCK_OWNED=0
    cc_log "released lock"
    unset lr__holder
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

# lock__holder_pid - print the pid recorded in the lock dir (empty if none).
lock__holder_pid() {
  lhp__pid="$(cat "$CLAUDECRON_LOCK_DIR/pid" 2>/dev/null | tr -dc '0-9')"
  printf '%s\n' "$lhp__pid"
  unset lhp__pid
}

# lock__holder_alive - return 0 if the lock records a pid that is still a live
# process. Returns 1 when there is no readable pid (unknowable -> not provably
# alive) or the process is gone.
lock__holder_alive() {
  lha__pid="$(lock__holder_pid)"
  if [ -z "$lha__pid" ]; then
    unset lha__pid
    return 1
  fi
  if kill -0 "$lha__pid" 2>/dev/null; then
    unset lha__pid
    return 0
  fi
  unset lha__pid
  return 1
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

  # Could not acquire: decide whether to steal.
  #
  # Liveness is authoritative: if the recorded holder pid is still a running
  # process, we NEVER steal, no matter how old the lock is. A long-running loop
  # (hours) is normal and must not be trampled by the next wake - that was the
  # original bug that spawned concurrent runners and a duplicate-post storm.
  #
  # We only steal when the holder is provably gone (dead pid) or unknowable
  # (no readable pid) AND the lock has aged past the staleness threshold. The
  # age gate guards the unknowable-pid case so a brand-new lock written by a
  # runner that has not yet recorded its pid is not stolen out from under it.
  if lock__holder_alive; then
    cc_log "another runner (pid $(lock__holder_pid)) holds the lock; skipping this run"
    exit 0
  fi

  la__stale_min="$(cfg_get lock_stale_minutes 30)"
  case "$la__stale_min" in
    ''|*[!0-9]* ) la__stale_min=30 ;;
  esac
  la__stale_sec=$(( la__stale_min * 60 ))

  la__mtime="$(lock__mtime_epoch "$CLAUDECRON_LOCK_DIR")"
  la__now="$(lock__now_epoch)"
  la__pid="$(lock__holder_pid)"

  # Dead holder with a known pid -> reclaim immediately (no need to wait out
  # the staleness window; we have positive proof the owner is gone).
  if [ -n "$la__pid" ]; then
    cc_log "lock holder pid $la__pid is dead; reclaiming"
    if lock__steal_and_acquire; then
      unset la__stale_min la__stale_sec la__mtime la__now la__pid
      return 0
    fi
    cc_log "another runner reclaimed the lock first; skipping"
    unset la__stale_min la__stale_sec la__mtime la__now la__pid
    exit 0
  fi

  # Unknown holder (no pid file): fall back to the age gate so we do not race
  # a runner that has just created the lock but not yet written its pid.
  if [ -n "$la__mtime" ] && [ -n "$la__now" ]; then
    la__age=$(( la__now - la__mtime ))
    if [ "$la__age" -ge "$la__stale_sec" ]; then
      cc_log "stealing stale lock with no live holder (age ${la__age}s >= ${la__stale_sec}s threshold)"
      if lock__steal_and_acquire; then
        unset la__stale_min la__stale_sec la__mtime la__now la__pid la__age
        return 0
      fi
      cc_log "another runner reclaimed the lock first; skipping"
      unset la__stale_min la__stale_sec la__mtime la__now la__pid la__age
      exit 0
    fi
  fi

  cc_log "another runner holds the lock; skipping this run"
  unset la__stale_min la__stale_sec la__mtime la__now la__pid la__age
  exit 0
}

# lock__steal_and_acquire - remove the current lock dir and try to re-create
# it as ours. Returns 0 and arms the release trap on success.
lock__steal_and_acquire() {
  rm -rf "$CLAUDECRON_LOCK_DIR" 2>/dev/null || true
  if lock__try_mkdir; then
    CLAUDECRON_LOCK_OWNED=1
    lock__install_trap
    printf '%s\n' "$$" > "$CLAUDECRON_LOCK_DIR/pid" 2>/dev/null || true
    cc_log "acquired lock after reclaiming"
    return 0
  fi
  return 1
}
