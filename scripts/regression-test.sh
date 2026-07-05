#!/usr/bin/env bash
# regression-test.sh - token-free regression tests for the runner core.
# Each test stands up an isolated CLAUDECRON_HOME in a temp dir and drives the
# real CLI. No claude/codex call, zero tokens, no network.
#
#   1. disabled loops are skipped by a wake pass
#   2. a stdin-reading backend cannot starve later loops in the same pass
#   3. a lock held by a LIVE runner is never stolen; a dead holder's is
#   4. lock_release leaves a lock alone once another process owns it
#   5. a failing loop fires the on_failure_cmd hook
#   6. a loop that missed many windows catches up with ONE run, not N
#   7. a backend that exceeds the run timeout is killed and recorded as error
#
# No `set -e`: each test records pass/fail explicitly and many steps are
# expected to return non-zero (skipped runs, absent files); an early exit
# would abort the whole suite on the first such step.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/bin/claudecron"
HOST="$(hostname -s)"
PASS=0
FAIL=0

t_ok()   { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
t_fail() { printf 'not ok - %s\n' "$1"; FAIL=$((FAIL + 1)); }

# JSON helpers (claudecron no longer depends on jq at runtime, so the tests
# don't either). jget <file> <key> prints a top-level scalar or empty.
jget() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        v = json.load(f).get(sys.argv[2], "")
except Exception:
    v = ""
print("" if v is None else v)
PY
}
# jset_str <file> <key> <string-value> - set a top-level string key in place.
jset_str() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
p = sys.argv[1]
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
d[sys.argv[2]] = sys.argv[3]
with open(p, "w") as f:
    json.dump(d, f, indent=2)
PY
}
# jset_num <file> <key> <number-value> - set a top-level numeric key in place.
jset_num() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
p = sys.argv[1]
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
d[sys.argv[2]] = int(sys.argv[3])
with open(p, "w") as f:
    json.dump(d, f, indent=2)
PY
}

# fresh_home - new isolated data home; sets TMP and CLAUDECRON_HOME.
fresh_home() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/claudecron-reg.XXXXXX")"
  export HOME="$TMP/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export CLAUDECRON_HOME="$XDG_CONFIG_HOME/claudecron"
  mkdir -p "$HOME"
  "$BIN" init --no-scheduler --no-skills >/dev/null 2>&1
}

cleanup_home() {
  rm -rf "$TMP"
  unset CLAUDECRON_TEST_BACKEND_CMD 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. disabled loops are skipped by a wake pass
# ---------------------------------------------------------------------------
test_disabled_loop_is_skipped() {
  fresh_home
  export CLAUDECRON_TEST_BACKEND_CMD="touch '$TMP/dis-ran'"
  "$BIN" add dis --interval 1 --cwd "$TMP" --tools Read --backend claude \
    --prompt noop --disabled >/dev/null 2>&1
  "$BIN" run >/dev/null 2>&1 || true

  if [ ! -f "$TMP/dis-ran" ]; then
    t_ok 'disabled loop does not run on a wake pass'
  else
    t_fail 'disabled loop does not run on a wake pass'
  fi
  if grep -q 'skip id=dis reason=disabled' "$CLAUDECRON_HOME/logs/runner.log" 2>/dev/null; then
    t_ok 'disabled loop skip is logged'
  else
    t_fail 'disabled loop skip is logged'
  fi
  cleanup_home
}

# ---------------------------------------------------------------------------
# 2. a stdin-reading backend cannot starve later loops in the same pass
#    (uses a fake claude binary because the real bug is stdin inheritance,
#    which the test seam does not exercise)
# ---------------------------------------------------------------------------
test_stdin_reader_does_not_starve_pass() {
  fresh_home
  cat > "$TMP/fake-claude" <<'EOS'
#!/bin/sh
# Behave like claude -p: read and discard all of stdin, then emit output.
cat > /dev/null
echo fake-claude-output
EOS
  chmod +x "$TMP/fake-claude"
  jset_str "$CLAUDECRON_HOME/config.json" claude_bin "$TMP/fake-claude"

  for id in aaa bbb ccc; do
    "$BIN" add "$id" --interval 1 --cwd "$TMP" --tools Read --backend claude \
      --prompt noop >/dev/null 2>&1
  done
  "$BIN" run >/dev/null 2>&1 || true

  local all_ok=1
  for id in aaa bbb ccc; do
    status="$(jget "$CLAUDECRON_HOME/state/$HOST/$id.json" last_status)"
    [ "$status" = "ok" ] || all_ok=0
  done
  if [ "$all_ok" = "1" ]; then
    t_ok 'all three loops ran despite a stdin-eating backend'
  else
    t_fail 'all three loops ran despite a stdin-eating backend'
  fi
  if grep -q 'wake done.*processed=3' "$CLAUDECRON_HOME/logs/runner.log" 2>/dev/null; then
    t_ok 'pass processed the whole registry'
  else
    t_fail 'pass processed the whole registry'
  fi
  cleanup_home
}

# ---------------------------------------------------------------------------
# 3. a wake pass never runs while another runner holds the lock; once the
#    holder releases, the next pass runs. Exercises the real lock end-to-end
#    by holding the same advisory lock the runner uses from a helper process.
# ---------------------------------------------------------------------------
test_live_lock_never_stolen() {
  fresh_home
  export CLAUDECRON_TEST_BACKEND_CMD="touch '$TMP/loop-ran'"
  "$BIN" add lk --interval 1 --cwd "$TMP" --tools Read --backend claude \
    --prompt noop >/dev/null 2>&1

  # Hold the runner's lockfile from a background helper: flock, signal ready,
  # then block until told to release. This is the same lock the runner takes,
  # so a competing 'run' must skip while we hold it.
  lockfile="$CLAUDECRON_HOME/lock/runner.lock"
  mkdir -p "$CLAUDECRON_HOME/lock"
  ready="$TMP/held.ready"; releasefifo="$TMP/release"
  mkfifo "$releasefifo"
  python3 - "$lockfile" "$ready" "$releasefifo" <<'PY' &
import fcntl, os, sys
lockfile, ready, releasefifo = sys.argv[1], sys.argv[2], sys.argv[3]
fh = open(lockfile, "a+")
fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
open(ready, "w").close()
open(releasefifo).read()   # block until the test opens the fifo for writing
PY
  HOLDER_PID=$!
  # Wait for the holder to actually own the lock.
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$ready" ] && break; sleep 0.3; done

  "$BIN" run >/dev/null 2>&1 || true
  if [ ! -f "$TMP/loop-ran" ]; then
    t_ok 'a pass does not run while another runner holds the lock'
  else
    t_fail 'a pass does not run while another runner holds the lock'
  fi

  # Release the holder, then a fresh pass must run.
  echo go > "$releasefifo"
  wait "$HOLDER_PID" 2>/dev/null || true

  "$BIN" run >/dev/null 2>&1 || true
  if [ -f "$TMP/loop-ran" ]; then
    t_ok 'a pass runs once the lock is released'
  else
    t_fail 'a pass runs once the lock is released'
  fi
  cleanup_home
}

# ---------------------------------------------------------------------------
# 4. a crashed holder's advisory lock is not left dangling: flock is released
#    by the kernel when the holding process dies, so the next pass proceeds.
# ---------------------------------------------------------------------------
test_lock_freed_on_holder_death() {
  fresh_home
  export CLAUDECRON_TEST_BACKEND_CMD="touch '$TMP/loop-ran'"
  "$BIN" add lk --interval 1 --cwd "$TMP" --tools Read --backend claude \
    --prompt noop >/dev/null 2>&1

  lockfile="$CLAUDECRON_HOME/lock/runner.lock"
  mkdir -p "$CLAUDECRON_HOME/lock"
  ready="$TMP/held2.ready"
  # Helper takes the lock, signals ready, then exits (dies) - the kernel frees
  # the flock. No fifo: the process just returns.
  python3 - "$lockfile" "$ready" <<'PY'
import fcntl, sys
fh = open(sys.argv[1], "a+")
fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
# fall off the end -> process exits -> lock released by the kernel
PY

  "$BIN" run >/dev/null 2>&1 || true
  if [ -f "$TMP/loop-ran" ]; then
    t_ok 'a dead holder does not leave a dangling lock'
  else
    t_fail 'a dead holder does not leave a dangling lock'
  fi
  cleanup_home
}

# ---------------------------------------------------------------------------
# 5. a failing loop fires the on_failure_cmd hook
# ---------------------------------------------------------------------------
test_failure_hook_fires() {
  fresh_home
  export CLAUDECRON_TEST_BACKEND_CMD="exit 7"
  "$BIN" add failer --interval 1 --cwd "$TMP" --tools Read --backend claude \
    --prompt noop >/dev/null 2>&1
  jset_str "$CLAUDECRON_HOME/config.json" on_failure_cmd \
    'printf "%s %s %s\n" "$CLAUDECRON_LOOP_ID" "$CLAUDECRON_RESULT" "$CLAUDECRON_RC" >> "$CLAUDECRON_NOTIFY_TEST_FILE"'
  export CLAUDECRON_NOTIFY_TEST_FILE="$TMP/notify.log"

  "$BIN" run >/dev/null 2>&1 || true

  if grep -q '^failer error 7$' "$TMP/notify.log" 2>/dev/null; then
    t_ok 'on_failure_cmd fires with loop id, result, and rc'
  else
    t_fail 'on_failure_cmd fires with loop id, result, and rc'
  fi
  unset CLAUDECRON_NOTIFY_TEST_FILE
  cleanup_home
}

# ---------------------------------------------------------------------------
# 6. a loop that missed many windows catches up with ONE run, not N
# ---------------------------------------------------------------------------
test_missed_windows_coalesce() {
  fresh_home
  export CLAUDECRON_TEST_BACKEND_CMD="echo ran >> '$TMP/runs.log'"
  "$BIN" add late --interval 1 --cwd "$TMP" --tools Read --backend claude \
    --prompt noop >/dev/null 2>&1
  # Pretend the loop last ran an hour ago: 60 missed 1-minute windows.
  mkdir -p "$CLAUDECRON_HOME/state/$HOST"
  python3 - "$CLAUDECRON_HOME/state/$HOST/late.json" <<'PY'
import json, sys, time
with open(sys.argv[1], "w") as f:
    json.dump({"last_run": int(time.time()) - 3600,
               "last_status": "ok", "last_duration_s": 1}, f)
PY

  "$BIN" run >/dev/null 2>&1 || true
  "$BIN" run >/dev/null 2>&1 || true

  runs="$(wc -l < "$TMP/runs.log" 2>/dev/null | tr -d ' ')"
  if [ "$runs" = "1" ]; then
    t_ok 'sixty missed windows coalesce into exactly one catch-up run'
  else
    t_fail "sixty missed windows coalesce into exactly one catch-up run (got ${runs:-0})"
  fi
  cleanup_home
}

# ---------------------------------------------------------------------------
# 7. a backend that exceeds the run timeout is killed and recorded as error
# ---------------------------------------------------------------------------
test_run_timeout_kills_hung_backend() {
  fresh_home
  export CLAUDECRON_TEST_BACKEND_CMD="sleep 300"
  export CLAUDECRON_RUN_TIMEOUT_S=3
  "$BIN" add hung --interval 1 --cwd "$TMP" --tools Read --backend claude \
    --prompt noop >/dev/null 2>&1

  start="$(date +%s)"
  "$BIN" run >/dev/null 2>&1 || true
  elapsed=$(( $(date +%s) - start ))

  status="$(jget "$CLAUDECRON_HOME/state/$HOST/hung.json" last_status)"
  if [ "$status" = "error" ] && [ "$elapsed" -lt 60 ]; then
    t_ok 'hung backend is killed at the timeout and recorded as error'
  else
    t_fail "hung backend is killed at the timeout and recorded as error (status=${status:-none} elapsed=${elapsed}s)"
  fi
  unset CLAUDECRON_RUN_TIMEOUT_S
  cleanup_home
}

# ---------------------------------------------------------------------------
# 8. the on_failure_cmd wired by init fires the claudecron-notify helper, which
#    enqueues every failure and coalesces repeat local alerts by (loop, rc).
# ---------------------------------------------------------------------------
test_notify_helper_enqueues_and_coalesces() {
  fresh_home
  NOTIFY="$REPO/bin/claudecron-notify"
  [ -x "$NOTIFY" ] || { t_fail 'claudecron-notify helper is present and executable'; cleanup_home; return; }
  # Force the local-notify fallback (no popup subprocess) by masking the
  # notifier tools: point HOME at the temp tree; on CI there is no osascript/
  # notify-send, so it appends to logs/alerts.log - which we assert on.
  mkdir -p "$CLAUDECRON_HOME/logs"

  # Two identical failures + one distinct rc.
  CLAUDECRON_LOOP_ID=nx CLAUDECRON_RC=1 CLAUDECRON_HOST="$HOST" \
    CLAUDECRON_LOG_TAIL=$'boot\nerror: alpha' python3 "$NOTIFY"
  CLAUDECRON_LOOP_ID=nx CLAUDECRON_RC=1 CLAUDECRON_HOST="$HOST" \
    CLAUDECRON_LOG_TAIL=$'error: alpha again' python3 "$NOTIFY"
  CLAUDECRON_LOOP_ID=nx CLAUDECRON_RC=9 CLAUDECRON_HOST="$HOST" \
    CLAUDECRON_LOG_TAIL=$'error: beta' python3 "$NOTIFY"

  qlines="$(wc -l < "$CLAUDECRON_HOME/failures.ndjson" 2>/dev/null | tr -d ' ')"
  if [ "$qlines" = "3" ]; then
    t_ok 'notify helper enqueues every failure (audit trail)'
  else
    t_fail "notify helper enqueues every failure (got ${qlines:-0}, want 3)"
  fi

  # The dedup file should show the repeated (nx,1) key suppressed once (count=1).
  cnt="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("nx|1",{}).get("count",0))' \
    "$CLAUDECRON_HOME/.notify-dedup.json" 2>/dev/null)"
  if [ "$cnt" = "1" ]; then
    t_ok 'notify helper coalesces a repeat (loop,rc) within the cooldown'
  else
    t_fail "notify helper coalesces a repeat (loop,rc) (suppressed count=${cnt:-none}, want 1)"
  fi
  cleanup_home
}

test_disabled_loop_is_skipped
test_stdin_reader_does_not_starve_pass
test_live_lock_never_stolen
test_lock_freed_on_holder_death
test_failure_hook_fires
test_missed_windows_coalesce
test_run_timeout_kills_hung_backend
test_notify_helper_enqueues_and_coalesces

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
