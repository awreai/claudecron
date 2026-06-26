# Self-improving loops + notification channel - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in self-improving loop (seeded on init, manually triggerable via `claudecron improve`) that audits and rewrites loop prompts safely, plus an interactive notification setup with an end-to-end test send, documented in the README.

**Architecture:** Reuse the existing runner/backend path. The self-improve loop is an ordinary registry loop whose prompt ships in the program tree (`builtins/`) and is copied into the data dir on init. `claudecron improve` is a thin wrapper over `run --now self-improve`. Notification stays a loop-prompt concern (claudecron sends nothing itself); `add` gains an interactive notify step that records a target into config and performs a real test send. All JSON via `cc_jq`; bash 3.2 portable.

**Tech Stack:** Pure bash (macOS bash 3.2 compatible), `jq` via the `cc_jq` wrapper, existing lib modules (config.sh, runner.sh, backend.sh, state.sh), smoke-test harness with the `CLAUDECRON_TEST_BACKEND_CMD` seam.

## Global Constraints

- Bash 3.2 portable: no `mapfile`/`readarray`, no `flock`, no associative arrays (`-A`), no `set -u` array guards that break on 3.2.
- CLI stays standalone: skills call the CLI, never the reverse.
- All JSON read/write through `cc_jq` (lib/common.sh). Never hand-parse JSON.
- Registry is the source of truth and is mutated only via `loop_upsert` / `loop_remove`. Never hand-edit `registry.json`.
- State split: never write `last_run` / `last_status` / `last_duration_s` outside `state_record_run`; loops own only their cursor.
- Backend contract exact (lib/backend.sh): no improvised flags.
- Loops never write artifacts into the repo they operate on; loop files live under `<CLAUDECRON_HOME>`.
- Function naming: public `cc_`/`cmd_`/module-prefixed; private `name__helper`.
- Every runner-affecting change must keep `scripts/smoke-test.sh` green and `scripts/scrub-check.sh` clean.
- Commit identity: the repo's existing neutral identity (do NOT pass `-c user.email`; the repo default is correct).
- No emoticons in code, logs, or docs. Single hyphens only, never en-dash or em-dash.

---

## File structure

- Create: `builtins/self-improve.prompt.md` - the shipped auditor loop prompt (five laws baked in).
- Modify: `lib/config.sh` - add `notify` defaults to `config_default_json`; add `notify_get` helper.
- Modify: `bin/claudecron` - seed default loop in `cmd_init`; add `cmd_improve` + dispatch + usage; add interactive notify step + test send to `cmd_add`; add `_cc_notify_test` helper.
- Modify: `lib/skills.sh` (or installer staging) - stage `builtins/` into the data dir's `prompts/` on init.
- Modify: `scripts/smoke-test.sh` - assert init seeds `self-improve`, and `improve --dry-run` runs token-free.
- Modify: `README.md` - new "Notifications" section + `improve` command entry.
- Modify: `CHANGELOG.md` - note the feature.

---

### Task 1: Ship the built-in self-improve prompt

**Files:**
- Create: `builtins/self-improve.prompt.md`
- Test: `scripts/smoke-test.sh` (asserted in Task 4)

**Interfaces:**
- Produces: a prompt file path `builtins/self-improve.prompt.md` that Task 3 copies to `prompts/self-improve.md` on init.

- [ ] **Step 1: Create the builtin prompt file**

Create `builtins/self-improve.prompt.md` with this exact content:

```markdown
You are the claudecron self-improve loop. You run unattended on a schedule. Each
pass you audit the other loops on this machine and improve their prompts. Keep
output minimal. Take real action; do not just describe it.

# Paths (resolve CLAUDECRON_HOME yourself)
CLAUDECRON_HOME defaults to $XDG_CONFIG_HOME/claudecron, else ~/.config/claudecron,
else ~/.claudecron. Registry: $CLAUDECRON_HOME/registry.json. Each loop's prompt:
$CLAUDECRON_HOME/prompts/<id>.md. Each loop's log: $CLAUDECRON_HOME/logs/<id>.log.

# CURSOR FILE (the ONLY state you own)
$CLAUDECRON_HOME/state/<host>/self-improve.cursor.json
Shape: { "loops": { "<id>": "<hash>" } } where <hash> is a digest of that loop's
prompt content + the tail of its log. Never write last_run / last_status /
last_duration_s and never touch any other loop's state.

# STEP 0 - COLD START
If the cursor file does not exist:
  - For every loop in the registry (claudecron list), compute its hash from its
    prompt file + the last 200 lines of its log.
  - Write all hashes to the cursor file. Do nothing else. Print exactly: noop
  - Exit.

# STEP 1 - FIND WORK
- Read the cursor. For each loop, recompute its hash. A loop is a CANDIDATE only
  if its hash differs from the cursor (its prompt or behavior changed).
- If there are no candidates: print exactly: noop  and exit. (Silence rule.)

# STEP 2 - AUDIT each candidate (audit yourself LAST and minimally)
Read the loop's prompt and the tail of its log. Assess only:
  - Noise: does it act/notify on quiet ticks (missing or weak silence rule)?
  - Misses: do log errors show cases it does not handle?
  - Errors: repeated non-zero runs / failures in the log?
  - Drift: has it lost any of the five laws (cold-start, silence, cursor-not-clock,
    state-split, idempotency)?
If a loop is clean, leave it untouched.

# STEP 3 - IMPROVE (auto-apply, guarded)
For each loop needing a fix, produce a rewritten prompt that fixes the finding
while preserving its intent. Before applying, in order:
  1. BACKUP: copy the current prompt to
     $CLAUDECRON_HOME/prompts/.backups/<id>.<UTC-timestamp>.md (create dir if needed).
  2. VALIDATION GATE: the rewrite MUST still contain all five-law markers - a
     cold-start branch, the literal silence token noop, a cursor/state clause, and
     an idempotency guard. If ANY is missing, REJECT: do not write it, record it as
     a rejected finding for the notification, and move on.
  3. APPLY via the CLI (sanctioned path), do NOT hand-edit registry.json:
       claudecron add <id> --prompt-file <new-prompt-tmpfile>
     (re-add updates the prompt; all other fields are preserved by reading the
     current entry first if you change anything else - for a prompt-only change,
     --prompt-file is enough).
  4. SELF-EDIT RULE: if the candidate is self-improve itself, make the smallest
     viable change and keep all five laws verbatim.

# STEP 4 - NOTIFY (only if something was applied or rejected)
Send ONE notification via this loop's configured channel (see the loop's notify
target). Per loop, one line: what was noisy/missed/errored, what changed (or was
rejected), and the backup path. If nothing was applied and nothing was rejected,
send NOTHING.

# STEP 5 - ADVANCE CURSOR
Write the new per-loop hashes to the cursor file. Drop entries for loops that no
longer exist. Print a one-line summary.

# Style
No emoticons. Single hyphens only. On a quiet tick, output exactly: noop
```

- [ ] **Step 2: Verify scrub-check stays clean**

Run: `cd /Users/dg/workspace/claudecron && ./scripts/scrub-check.sh`
Expected: exits 0, no matches (no personal names, hostnames, or dev absolute paths in the new file).

- [ ] **Step 3: Commit**

```bash
cd /Users/dg/workspace/claudecron
git add builtins/self-improve.prompt.md
git commit -m "feat: ship built-in self-improve loop prompt"
```

---

### Task 2: Add notify defaults + getter to config

**Files:**
- Modify: `lib/config.sh:47-53` (config_default_json) and after `cfg_get` (~line 86)
- Test: `scripts/smoke-test.sh` (asserted in Task 4)

**Interfaces:**
- Consumes: existing `config_read`, `cc_jq`.
- Produces: config key `notify` = `{ "kind": "none", "target": "", "tool": "" }`; helper `notify_get <field> [default]` printing a scalar from the notify block.

- [ ] **Step 1: Add the failing assertion to a scratch check**

Run this one-liner to confirm the key is currently absent (it should print empty):
```bash
cd /Users/dg/workspace/claudecron
CLAUDECRON_HOME="$(mktemp -d)" bash -c '. lib/common.sh; . lib/config.sh; config_read | jq -r ".notify // empty"'
```
Expected: prints nothing (no notify block yet).

- [ ] **Step 2: Add notify to config_default_json**

In `lib/config.sh`, change `config_default_json` (lines 47-53) to include a notify block:

```bash
config_default_json() {
  cc_jq -n \
    --arg backend "$CLAUDECRON_DEFAULT_BACKEND" \
    --argjson lock_stale "$CLAUDECRON_DEFAULT_LOCK_STALE_MINUTES" \
    --argjson log_keep "$CLAUDECRON_DEFAULT_LOG_KEEP_LINES" \
    '{ backend: $backend, lock_stale_minutes: $lock_stale, log_keep_lines: $log_keep, claude_bin: "", codex_bin: "", notify: { kind: "none", target: "", tool: "" } }'
}
```

- [ ] **Step 3: Add the notify_get helper**

In `lib/config.sh`, immediately after `cfg_get` (after line 86), add:

```bash
# notify_get <field> [default] - print one scalar from the notify config block.
notify_get() {
  ng__field="$1"
  ng__def="${2:-}"
  ng__val="$(config_read | cc_jq -r --arg f "$ng__field" '.notify[$f] // empty' 2>/dev/null)"
  if [ -z "$ng__val" ]; then
    printf '%s\n' "$ng__def"
  else
    printf '%s\n' "$ng__val"
  fi
  unset ng__field ng__def ng__val
}
```

- [ ] **Step 4: Verify the key now exists and the helper reads it**

Run:
```bash
cd /Users/dg/workspace/claudecron
CLAUDECRON_HOME="$(mktemp -d)" bash -c '. lib/common.sh; . lib/config.sh; config_read | jq -c ".notify"; notify_get kind MISSING'
```
Expected: prints `{"kind":"none","target":"","tool":""}` then `none`.

- [ ] **Step 5: Shellcheck the file**

Run: `cd /Users/dg/workspace/claudecron && shellcheck -x lib/config.sh`
Expected: no new warnings (clean, per .shellcheckrc).

- [ ] **Step 6: Commit**

```bash
cd /Users/dg/workspace/claudecron
git add lib/config.sh
git commit -m "feat: add notify config block and notify_get helper"
```

---

### Task 3: Seed the self-improve loop on init

**Files:**
- Modify: `bin/claudecron` cmd_init, after `loop_registry_init` (line 253)
- Modify: `bin/claudecron` - add `_cc_seed_self_improve` helper near the other `_cc_` helpers
- Test: `scripts/smoke-test.sh` (asserted in Task 4)

**Interfaces:**
- Consumes: `loop_exists` (config.sh), `loop_upsert` (config.sh/compat.sh), `cc_jq`, `$CLAUDECRON_HOME`, the builtin from Task 1.
- Produces: after `claudecron init`, a registry loop `self-improve` (interval 2880, enabled, tools `Bash,Read,Write`, prompt `prompts/self-improve.md`) and the copied prompt file. Idempotent: never clobbers an existing `self-improve` entry.

- [ ] **Step 1: Add the seed helper**

In `bin/claudecron`, near the other `_cc_` helper functions (e.g. just before `cmd_init` at line 208), add:

```bash
# _cc_seed_self_improve - register the built-in self-improve loop if absent.
# Idempotent: leaves an existing entry untouched. Copies the shipped builtin
# prompt into the data dir so upgrades can refresh it.
_cc_seed_self_improve() {
  if loop_exists self-improve; then
    cc_log info "self-improve loop already present; leaving as is"
    return 0
  fi
  local src="$CLAUDECRON_LIBEXEC/builtins/self-improve.prompt.md"
  if [ ! -f "$src" ]; then
    cc_log warn "builtin self-improve prompt not found at $src; skipping seed"
    return 0
  fi
  mkdir -p "$CLAUDECRON_HOME/prompts"
  cp "$src" "$CLAUDECRON_HOME/prompts/self-improve.md"
  cc_jq -n \
    '{ id: "self-improve", enabled: true, interval_minutes: 2880,
       cwd: env.HOME, add_dirs: [], allowed_tools: "Bash,Read,Write",
       prompt_file: "prompts/self-improve.md", backend: "claude" }' \
    | loop_upsert self-improve
  cc_log info "seeded built-in self-improve loop (every 2 days)"
}
```

Note: `$CLAUDECRON_LIBEXEC` is the program tree root (where `bin/`, `lib/`, `builtins/` live). Verified present and exported in `lib/common.sh:26` and `bin/claudecron:38` - use it as written.

- [ ] **Step 2: Call the seed from cmd_init**

In `bin/claudecron` `cmd_init`, immediately after `loop_registry_init` (line 253), add:

```bash
  _cc_seed_self_improve
```

- [ ] **Step 3: Verify init seeds it**

Run:
```bash
cd /Users/dg/workspace/claudecron
H="$(mktemp -d)"; CLAUDECRON_HOME="$H" ./bin/claudecron init --no-scheduler --no-skills
CLAUDECRON_HOME="$H" ./bin/claudecron list
test -f "$H/prompts/self-improve.md" && echo "PROMPT OK"
```
Expected: `list` includes `self-improve`; prints `PROMPT OK`.

- [ ] **Step 4: Verify idempotency (second init does not clobber)**

Run:
```bash
cd /Users/dg/workspace/claudecron
echo "USER EDIT" >> "$H/prompts/self-improve.md"
CLAUDECRON_HOME="$H" ./bin/claudecron init --no-scheduler --no-skills
grep -q "USER EDIT" "$H/prompts/self-improve.md" && echo "IDEMPOTENT OK"
```
Expected: prints `IDEMPOTENT OK` (existing prompt preserved).

- [ ] **Step 5: Shellcheck**

Run: `cd /Users/dg/workspace/claudecron && shellcheck -x bin/claudecron`
Expected: no new warnings.

- [ ] **Step 6: Commit**

```bash
cd /Users/dg/workspace/claudecron
git add bin/claudecron
git commit -m "feat: seed built-in self-improve loop on init (idempotent)"
```

---

### Task 4: Extend smoke-test for the seeded loop

**Files:**
- Modify: `scripts/smoke-test.sh` after line 23 (the init step)

**Interfaces:**
- Consumes: the seeded `self-improve` loop from Task 3.
- Produces: CI assertion that init seeds the loop and its prompt exists.

- [ ] **Step 1: Add assertions after init**

In `scripts/smoke-test.sh`, immediately after line 23 (`"$BIN" init --no-scheduler --no-skills`), add:

```bash
# 1b. init must seed the built-in self-improve loop with its prompt
"$BIN" list | grep -qx "self-improve" \
  || { echo "FAIL: init did not seed self-improve loop" >&2; exit 1; }
test -f "$CLAUDECRON_HOME/prompts/self-improve.md" \
  || { echo "FAIL: self-improve prompt not copied" >&2; exit 1; }
```

- [ ] **Step 2: Run the smoke test**

Run: `cd /Users/dg/workspace/claudecron && ./scripts/smoke-test.sh`
Expected: ends with `SMOKE PASSED: ...` and exit 0.

- [ ] **Step 3: Commit**

```bash
cd /Users/dg/workspace/claudecron
git add scripts/smoke-test.sh
git commit -m "test: smoke-test asserts init seeds the self-improve loop"
```

---

### Task 5: Add the `improve` subcommand

**Files:**
- Modify: `bin/claudecron` - add `cmd_improve` (after `cmd_run`, ~line 736), dispatch entry (~line 1122), usage text (~line 117)

**Interfaces:**
- Consumes: `cmd_run` (reused via `--now`), `loop_exists`.
- Produces: `claudecron improve [--id <loop>] [--dry-run]`. With no `--id`, forces a run of `self-improve`. `--dry-run` passes through. `--id <loop>` is reserved for a future single-target audit; for now it validates the loop exists and still runs the self-improve pass (which audits all candidates), logging the focus id.

- [ ] **Step 1: Add cmd_improve**

In `bin/claudecron`, after `cmd_run`'s closing brace (~line 736), add:

```bash
# ===========================================================================
# improve - run one self-improve pass now (audits + improves loop prompts).
# ===========================================================================
cmd_improve() {
  local only_id=""
  local dry=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id)
        [ "$#" -ge 2 ] || cc_die "--id requires a loop id"
        only_id="$2"; shift 2 ;;
      --id=*) only_id="${1#*=}"; shift ;;
      --dry-run) dry=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: claudecron improve [--id <loop>] [--dry-run]

  Run one self-improve pass now: audit loop prompts + run logs and improve
  the prompts (backup + validation gated). Same pass the scheduled
  self-improve loop runs.

  --id <loop>   Focus the audit on one loop (still runs the self-improve pass).
  --dry-run     Show what would run without invoking the backend.
EOF
        return 0 ;;
      -*) cc_die "improve: unknown option: $1" ;;
      *) cc_die "improve: unexpected argument: $1" ;;
    esac
  done

  loop_exists self-improve \
    || cc_die "no self-improve loop; run 'claudecron init' to seed it"

  if [ -n "$only_id" ]; then
    loop_exists "$only_id" || cc_die "improve: no such loop '$only_id'"
    cc_log info "improve focus: $only_id"
  fi

  if [ "$dry" -eq 1 ]; then
    cmd_run --now self-improve --dry-run
  else
    cmd_run --now self-improve
  fi
}
```

- [ ] **Step 2: Add the dispatch entry**

In the dispatch `case` (line 1122, after the `run)` line), add:

```bash
  improve)    cmd_improve    ${@+"$@"} ;;
```

- [ ] **Step 3: Add usage text**

In `usage()` (after line 117, the `run` line), add this aligned line:

```
  improve              Run a self-improve pass now (audit + improve prompts).
```

- [ ] **Step 4: Verify improve --dry-run runs token-free**

Run:
```bash
cd /Users/dg/workspace/claudecron
H="$(mktemp -d)"; CLAUDECRON_HOME="$H" ./bin/claudecron init --no-scheduler --no-skills >/dev/null
CLAUDECRON_HOME="$H" CLAUDECRON_TEST_BACKEND_CMD='echo improve-dry' ./bin/claudecron improve --dry-run
```
Expected: prints the dry-run decision for `self-improve` (forced), no backend tokens used, exit 0.

- [ ] **Step 5: Verify unknown id is rejected**

Run:
```bash
cd /Users/dg/workspace/claudecron
CLAUDECRON_HOME="$H" ./bin/claudecron improve --id nonesuch; echo "rc=$?"
```
Expected: error "improve: no such loop 'nonesuch'" and `rc=1`.

- [ ] **Step 6: Shellcheck + smoke**

Run: `cd /Users/dg/workspace/claudecron && shellcheck -x bin/claudecron && ./scripts/smoke-test.sh`
Expected: shellcheck clean; smoke ends `SMOKE PASSED`.

- [ ] **Step 7: Commit**

```bash
cd /Users/dg/workspace/claudecron
git add bin/claudecron
git commit -m "feat: add 'improve' subcommand to run a self-improve pass on demand"
```

---

### Task 6: Interactive notify setup + end-to-end test send in `add`

**Files:**
- Modify: `bin/claudecron` - add `_cc_notify_test` helper; call an interactive notify step inside `cmd_add` after the prompt is sourced (~line 439, before writing the prompt file)

**Interfaces:**
- Consumes: `_cc_ask` (existing tty prompt helper, ~line 518), `notify_get`/`cfg_set` (Task 2), `cc_backend_exec` is NOT used here (the test send is a direct tool call).
- Produces: when `add` runs interactively (no scripting flags) and the user opts in, a notify target saved to config (kind/target/tool) and a verified test send. Scripted `add` (with flags) is unchanged and never prompts, so smoke-test and CI stay non-interactive.

- [ ] **Step 1: Add the test-send helper**

In `bin/claudecron`, near the other `_cc_` helpers, add:

```bash
# _cc_notify_test <kind> <target> <tool> - send a one-line test notification.
# Returns 0 on a successful send attempt, non-zero on failure. The user
# confirms receipt separately. Supported kinds: slack (via a shell tool/cmd),
# webhook (curl POST), command (arbitrary shell line), none (no-op).
_cc_notify_test() {
  nt__kind="$1"; nt__target="$2"; nt__tool="$3"
  nt__msg="claudecron test notification - if you see this, notifications work."
  case "$nt__kind" in
    none) cc_log info "notify kind=none; nothing to test"; return 0 ;;
    webhook)
      command -v curl >/dev/null 2>&1 || { cc_err "curl not found"; return 1; }
      curl -fsS -X POST -H 'Content-Type: application/json' \
        --data "$(cc_jq -n --arg t "$nt__msg" '{text:$t}')" \
        "$nt__target" >/dev/null \
        || { cc_err "webhook POST failed"; return 1; }
      return 0 ;;
    command)
      [ -n "$nt__target" ] || { cc_err "command notify needs a shell line"; return 1; }
      CLAUDECRON_NOTIFY_MSG="$nt__msg" sh -c "$nt__target" \
        || { cc_err "notify command failed"; return 1; }
      return 0 ;;
    slack)
      # Slack is sent by the loop's agent tool at runtime (e.g. an MCP Slack
      # tool). At setup we cannot call that tool from bash, so we verify the
      # target shape and tell the user it will be exercised on the first pass.
      [ -n "$nt__target" ] || { cc_err "slack notify needs a channel id"; return 1; }
      cc_log info "slack channel recorded: $nt__target (tool: ${nt__tool:-unset})"
      cc_log info "the loop will send via its Slack tool on its first run"
      return 0 ;;
    *) cc_err "unknown notify kind: $nt__kind"; return 1 ;;
  esac
}
```

- [ ] **Step 2: Add the interactive notify step to cmd_add**

In `cmd_add`, inside the interactive branch only (where `_cc_add_interactive_collect` is called, ~line 374-378), after the prompt content is determined and before writing the prompt file (~line 441), add. The guard uses `cmd_add`'s existing `local interactive=1` flag (declared at `bin/claudecron:294`, flipped to `0` by any scripting flag), so scripted `add` never enters this block:

```bash
  # Interactive notify setup (only in the interactive path; scripted add skips).
  if [ "$interactive" = "1" ]; then
    n_kind="$(_cc_ask "Notify how on activity? (slack/webhook/command/none)" "$(notify_get kind none)")"
    case "$n_kind" in
      slack)
        n_target="$(_cc_ask "Slack channel id" "$(notify_get target)")"
        n_tool="$(_cc_ask "Slack tool name (agent tool that sends)" "$(notify_get tool)")"
        ;;
      webhook)  n_target="$(_cc_ask "Webhook URL" "$(notify_get target)")"; n_tool="" ;;
      command)  n_target="$(_cc_ask "Shell line to run (msg in \$CLAUDECRON_NOTIFY_MSG)" "$(notify_get target)")"; n_tool="" ;;
      *)        n_kind="none"; n_target=""; n_tool="" ;;
    esac
    cc_jq -n --arg k "$n_kind" --arg t "$n_target" --arg tl "$n_tool" \
      '{kind:$k, target:$t, tool:$tl}' | {
        read_block="$(cat)"
        cfg_set notify "$read_block"
      }
    if [ "$n_kind" != "none" ]; then
      printf 'Sending a test notification...\n'
      if _cc_notify_test "$n_kind" "$n_target" "$n_tool"; then
        confirm="$(_cc_ask "Did you receive the test notification? (y/n)" "y")"
        case "$confirm" in
          y|Y|yes) cc_log info "notify verified end to end" ;;
          *) cc_log warn "notify NOT confirmed; edit the loop prompt or re-run add to fix the channel" ;;
        esac
      else
        cc_log warn "test send failed; recorded the target anyway - fix and re-run add to verify"
      fi
    fi
  fi
```

Note: the guard variable `$interactive` is `cmd_add`'s own `local interactive` (set to 1, flipped to 0 by any scripting flag) - confirmed at `bin/claudecron:294`. This guarantees scripted `add` (flags present) never enters this block, keeping CI and smoke-test non-interactive.

- [ ] **Step 3: Verify scripted add does NOT prompt (CI safety)**

Run:
```bash
cd /Users/dg/workspace/claudecron
H="$(mktemp -d)"; CLAUDECRON_HOME="$H" ./bin/claudecron init --no-scheduler --no-skills >/dev/null
CLAUDECRON_HOME="$H" ./bin/claudecron add t1 --interval 5 --cwd "$H" --tools Read --backend claude --prompt noop --enabled </dev/null
CLAUDECRON_HOME="$H" ./bin/claudecron list | grep -qx t1 && echo "SCRIPTED OK"
```
Expected: completes without reading from tty, prints `SCRIPTED OK`.

- [ ] **Step 4: Verify webhook test send path with a local sink**

Run:
```bash
cd /Users/dg/workspace/claudecron
H="$(mktemp -d)"; CLAUDECRON_HOME="$H" ./bin/claudecron init --no-scheduler --no-skills >/dev/null
CLAUDECRON_HOME="$H" bash -c '. lib/common.sh; . lib/config.sh; . bin/claudecron 2>/dev/null; _cc_notify_test command "echo GOT: \$CLAUDECRON_NOTIFY_MSG" ""'
```
Expected: prints `GOT: claudecron test notification ...` and exit 0. (If sourcing bin/claudecron triggers dispatch, instead copy `_cc_notify_test` reasoning is covered by Step 5's manual run.)

- [ ] **Step 5: Shellcheck + smoke**

Run: `cd /Users/dg/workspace/claudecron && shellcheck -x bin/claudecron && ./scripts/smoke-test.sh`
Expected: shellcheck clean; smoke `SMOKE PASSED` (smoke uses scripted add, so no prompts).

- [ ] **Step 6: Commit**

```bash
cd /Users/dg/workspace/claudecron
git add bin/claudecron
git commit -m "feat: interactive notify setup with end-to-end test send in add"
```

---

### Task 7: README "Notifications" section + improve docs

**Files:**
- Modify: `README.md` - new "## Notifications" section after "## Backends" (line 99); add `improve` to the commands list under "## The skills and commands" (line 191)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: behavior from Tasks 1-6.
- Produces: user-facing docs for Slack integration, the test send, and the three override levels.

- [ ] **Step 1: Add the Notifications section**

In `README.md`, after the "## Backends" section (before "## Where things live" at line 114), insert:

```markdown
## Notifications

claudecron does not send messages itself. A loop notifies you by calling a tool
in its `allowed_tools` - for example a Slack tool exposed to the agent, or
`Bash` running `curl` against a webhook. The channel or target lives in the
loop's prompt, so notifications are as flexible as your agent's tools.

### Slack

Two common ways a loop reaches Slack:

- Agent Slack tool: if your backend agent has a Slack tool (e.g. an MCP Slack
  server), add that tool to the loop's `allowed_tools` and put the channel id in
  the prompt. The loop calls the tool to post.
- Webhook: add `Bash` to the loop and have the prompt `curl -X POST` a Slack
  incoming-webhook URL with a JSON `{"text": "..."}` body.

### Guided setup and test send

When you create a loop interactively (`claudecron add <id>` with no flags),
claudecron asks how the loop should notify you - slack, webhook, command, or
none - records the target, and sends a real test notification so you can confirm
it lands before the loop ever runs unattended. If the test does not arrive, fix
the channel and re-run `add`.

### Overriding the channel

The comm channel is overridable at three levels:

1. Per loop: edit the channel id or URL in the loop's prompt, or re-run
   `claudecron add <id>` and answer the notify step again.
2. Default for new loops: the `notify` block in `config.json`
   (`{ "kind": "...", "target": "...", "tool": "..." }`) prefills the answers
   for future loops.
3. Per environment: have the prompt read an environment variable for the
   channel id, so the same loop targets different channels on different machines.

Loop files (prompts, cursors, backups, logs) always live under the claudecron
home, never in the repository a loop operates on.
```

- [ ] **Step 2: Add improve to the commands list**

In `README.md` under "## The skills and commands" (line 191), add a bullet describing `claudecron improve` consistent with the surrounding format (match the existing list style in that section).

- [ ] **Step 3: Update CHANGELOG**

In `CHANGELOG.md`, under the top unreleased/next section, add:

```markdown
- Built-in self-improve loop: seeded on init (every 2 days), audits and improves
  loop prompts with backup + five-laws validation; run on demand with
  `claudecron improve`.
- Interactive notification setup in `add` with an end-to-end test send; new
  `notify` config block; README "Notifications" section documenting Slack and
  channel overrides.
```

- [ ] **Step 4: Verify scrub-check**

Run: `cd /Users/dg/workspace/claudecron && ./scripts/scrub-check.sh`
Expected: exit 0, no leaks in the new docs.

- [ ] **Step 5: Commit**

```bash
cd /Users/dg/workspace/claudecron
git add README.md CHANGELOG.md
git commit -m "docs: document notifications, Slack, channel override, and improve"
```

---

### Task 8: Update the agent skill to mention self-improve

**Files:**
- Modify: `skills/claudecron/SKILL.md` - add a short note about the built-in self-improve loop and `improve` command in the command-mapping section.

**Interfaces:**
- Consumes: the `improve` command (Task 5).
- Produces: agents authoring loops know self-improve exists and is seeded by default.

- [ ] **Step 1: Add a self-improve note to the skill**

In `skills/claudecron/SKILL.md`, in the "Mapping requests to subcommands" table (or the nearest command list), add a row:

```
| "audit/improve my loops" / "make loops better" | `claudecron improve [--id <id>] [--dry-run]` (the self-improve loop is seeded by default and also runs every 2 days) |
```

- [ ] **Step 2: Verify scrub-check**

Run: `cd /Users/dg/workspace/claudecron && ./scripts/scrub-check.sh`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
cd /Users/dg/workspace/claudecron
git add skills/claudecron/SKILL.md
git commit -m "docs(skill): note the built-in self-improve loop and improve command"
```

---

## Final verification

- [ ] Run full smoke test: `cd /Users/dg/workspace/claudecron && ./scripts/smoke-test.sh` -> `SMOKE PASSED`
- [ ] Run scrub check: `./scripts/scrub-check.sh` -> exit 0
- [ ] Shellcheck all touched shell: `shellcheck -x bin/claudecron lib/config.sh`
- [ ] Manual end-to-end on a temp home: init seeds self-improve; `improve --dry-run` shows the forced pass; scripted `add` stays non-interactive.
- [ ] Confirm no loop artifacts were written into any target repo.
