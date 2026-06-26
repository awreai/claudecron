#!/usr/bin/env bash
# smoke-test.sh - token-free proof the runner works end to end. Stands up an
# isolated CLAUDECRON_HOME in a temp dir, registers a dummy loop whose backend is
# a plain 'echo' (via the CLAUDECRON_TEST_BACKEND_CMD seam - no claude/codex call,
# zero tokens, no network), runs one pass through the same path the scheduler
# uses, and asserts that per-host state was written with last_status=ok.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/claudecron-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export CLAUDECRON_HOME="$XDG_CONFIG_HOME/claudecron"
mkdir -p "$HOME"
BIN="$REPO/bin/claudecron"
HOST="$(hostname -s)"

test -x "$BIN" || { echo "FAIL: $BIN not executable" >&2; exit 1; }

# 1. init without touching the OS scheduler or the real agent skill dirs
"$BIN" init --no-scheduler --no-skills

# 1b. init must seed the built-in self-improve loop with its prompt
"$BIN" list | grep -qx "self-improve" \
  || { echo "FAIL: init did not seed self-improve loop" >&2; exit 1; }
test -f "$CLAUDECRON_HOME/prompts/self-improve.md" \
  || { echo "FAIL: self-improve prompt not copied" >&2; exit 1; }

# 2. register a dummy loop backed by a fake 'echo' backend (test seam)
export CLAUDECRON_TEST_BACKEND_CMD='echo claudecron-smoke-ran'
"$BIN" add smoke \
  --interval 1 \
  --cwd "$TMP" \
  --tools "Read" \
  --backend claude \
  --prompt "noop" \
  --enabled

# 3. force one run through the SAME path the scheduler uses
"$BIN" run --now smoke

# 4. assert runner-owned state was written
STATE="$CLAUDECRON_HOME/state/$HOST/smoke.json"
test -f "$STATE" || { echo "FAIL: state file not written: $STATE" >&2; exit 1; }
status="$(jq -r '.last_status' "$STATE")"
last_run="$(jq -r '.last_run' "$STATE")"
[ "$status" = "ok" ] || { echo "FAIL: last_status=$status (want ok)" >&2; exit 1; }
{ [ -n "$last_run" ] && [ "$last_run" != "null" ]; } \
  || { echo "FAIL: last_run not set" >&2; exit 1; }

# 5. assert the loop's output landed in its log
grep -q "claudecron-smoke-ran" "$CLAUDECRON_HOME/logs/smoke.log" \
  || { echo "FAIL: loop output not logged" >&2; exit 1; }

echo "SMOKE PASSED: init + add + run --now wrote state ($status) and log."
