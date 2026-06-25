---
name: codex-claudecron
description: >-
  Set up and manage recurring background agent loops with claudecron, using the
  Codex backend. Use when the user says "run X every N minutes", "schedule this
  agent", "set up a loop", "keep checking X on an interval", or asks how a loop
  is doing / wants to stop or delete one, and the working agent is Codex. The
  claudecron CLI is fully standalone (pure bash, no runtime deps) and owns a
  local registry, prompts, per-host state, logs, and a launchd/systemd timer.
---

# claudecron (Codex backend)

claudecron runs a prompt against an agent backend on a fixed wall-clock
interval. This variant defaults to the **Codex** backend. Each scheduled task is
a **loop**: an id, an interval, a working directory, a backend, and a
self-contained prompt file. A local scheduler (launchd on macOS, systemd-user on
Linux) wakes a runner that executes every due, enabled loop.

Your job is to turn a fuzzy request like "check my open PRs every 15 minutes and
ping me" into a correct `claudecron add --backend codex` invocation with a
well-authored loop prompt.

## Golden rule: shell the CLI, never touch the files

The registry at `<CLAUDECRON_HOME>/registry.json` is the single source of truth
and is owned exclusively by the CLI. **Never** write, edit, or hand-merge
`registry.json`, `config.json`, or state files. Every create / change / query /
delete goes through a `claudecron` subcommand. Hand-editing JSON desyncs state,
corrupts the registry, and races the runner.

The CLI is standalone: pure bash that runs under macOS `/bin/bash` 3.2, no
package manager, no network install. If `claudecron` is not on PATH, tell the
user to install it; do not fabricate the registry.

## Where things live

Resolution of `CLAUDECRON_HOME`, in order: `$CLAUDECRON_HOME` ->
`$XDG_CONFIG_HOME/claudecron` -> `~/.config/claudecron` (fallback
`~/.claudecron`).

- Registry (source of truth): `<CLAUDECRON_HOME>/registry.json` shape `{ "loops": [ ... ] }`
- Global config: `<CLAUDECRON_HOME>/config.json`
- Prompts: `<CLAUDECRON_HOME>/prompts/<id>.md`
- Per-host state: `<CLAUDECRON_HOME>/state/<hostname-s>/<id>.json`
- Logs: `<CLAUDECRON_HOME>/logs/runner.log` and `<CLAUDECRON_HOME>/logs/<id>.log`
- Scheduler unit basename: `dev.claudecron.runner`

Program code lives separately under `~/.local/share/claudecron/` (`bin/`,
`lib/`, `templates/`). You do not edit that.

## Step 1 - gather intent

Pin down five things; ask only for what is missing.

1. **Task** - what runs each tick, one sentence.
2. **Interval** - `<N>m` minutes, **one-minute floor**. If unstated or
   "continuous", propose 15m and confirm. No sub-minute.
3. **cwd** - the absolute project directory. Codex receives this via `--cd`.
4. **backend** - default `codex` for this skill. Only switch to `claude` if the
   user explicitly wants it.
5. **Sandbox / approval surface** - instead of a Claude tool allowlist, Codex
   loops are bounded by a sandbox mode and an approval policy. claudecron runs
   Codex non-interactively as:
   `codex exec "$PROMPT" --cd "$CWD" --sandbox workspace-write --ask-for-approval never`.
   That means the loop can read and write within the workspace and run commands
   without prompting. There is no per-tool allowlist - **the prompt itself is
   your privilege boundary.** Keep the prompt's actions minimal and confined to
   the cwd. If a loop only needs to read, say so explicitly in the prompt and
   have it avoid writes.

Because `--ask-for-approval never` removes the human gate, be conservative: a
Codex loop should do the smallest, most clearly-scoped thing, and the prompt
must forbid anything outside its task.

## Step 2 - author a good loop prompt

A loop prompt runs unattended every tick, forever. Read `loop-prompt-guide.md`
in this skill directory and follow it exactly. Non-negotiables:

- **Cursor-not-clock.** Track a cursor (last id / timestamp / sha) in the loop's
  own state, never "since I last woke by clock".
- **Mandatory cold-start branch.** First run with no cursor: record the cursor,
  do nothing else, print `noop`, exit. Prevents a first-run flood.
- **Silence rule.** Nothing new since the cursor -> print `noop` and exit.
- **State split.** The loop owns ONLY its cursor file. It must NEVER write
  `last_run`, `last_status`, or `last_duration_s`, and never touch claudecron's
  state dir - those are runner bookkeeping.
- **Idempotency.** Existence check before any mutation, so a re-run never
  double-acts. This matters more under Codex, where the sandbox is
  write-enabled and unattended.

Write the prompt to a working-area file (e.g. `./loop-prompt.md`) and pass it
with `--prompt-file`. claudecron copies it into `<CLAUDECRON_HOME>/prompts/<id>.md`.

## Step 3 - create the loop

```bash
claudecron add <slug> \
  --interval <Nm> \
  --cwd <abs-dir> \
  --backend codex \
  --prompt-file <file>
```

Example (read-mostly PR babysitter, every 15 minutes):

```bash
claudecron add pr-babysitter \
  --interval 15m \
  --cwd /home/octocat/work/hello-world \
  --backend codex \
  --prompt-file ./loop-prompt.md
```

Note: for Codex you generally omit `--tools` since there is no allowlist; if your
claudecron build still accepts `--tools`, it is ignored by the Codex invocation.
The `<slug>` is the loop id, short kebab-case. Good ids: `pr-babysitter`,
`daily-digest`, `dep-watch`, `log-summarizer`, `issue-groomer`.

On first `add`, claudecron may need to install its scheduler (gated behind
`CLAUDECRON_INIT_SCHEDULER`). Surface that to the user; do not write the launchd
plist or systemd units yourself.

## Mapping requests to subcommands

| User says | Run |
|---|---|
| "run/schedule/loop X every N min" | `claudecron add <slug> --interval <Nm> --cwd <dir> --backend codex --prompt-file <file>` |
| "what loops do I have" / "how is X doing" / "status" | `claudecron status --json` |
| "pause X" / "stop X" (keep it) | `claudecron disable <id>` |
| "resume X" | `claudecron enable <id>` |
| "run X right now" | `claudecron run <id>` |
| "change X to every N min" / edit cwd/prompt | `claudecron add <id> ...` again with new flags |
| "show me X's output / logs" | `claudecron logs <id>` |
| "delete X" / "remove X for good" | `claudecron remove <id> --purge --yes` |

Parse `claudecron status --json` to answer "how is X" - it carries each loop's
enabled flag, interval, last_run, last_status, last_duration_s. Read those via
the CLI; never open the state JSON directly.

For destructive actions (`remove`, `--purge`), confirm the id unless the user
was explicit. `--purge` also deletes the prompt, state, and per-loop log.

## Backend invocation (for reference)

The runner executes Codex as:

```
codex exec "$PROMPT" --cd "$CWD" --sandbox workspace-write --ask-for-approval never
```

There is no per-tool allowlist; scope is the workspace sandbox plus whatever the
prompt instructs. Keep the prompt tight.

## Don't

- Don't write or edit `registry.json`, `config.json`, or any state file.
- Don't place prompt files into `<CLAUDECRON_HOME>/prompts/` yourself.
- Don't author a loop prompt without the cold-start branch and silence rule.
- Don't let a Codex loop roam outside its cwd or do more than its one task -
  there is no approval gate to catch it.
- Don't set sub-minute intervals.

Copyright (c) 2026 The claudecron authors
