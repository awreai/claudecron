---
name: claudecron
description: >-
  Set up and manage recurring background agent loops with claudecron. Use when
  the user says "run X every N minutes", "schedule this agent", "set up a loop",
  "keep checking X on an interval", "poll Y periodically", "babysit my PRs every
  15 minutes", or asks how a loop is doing / wants to stop or delete one. The
  claudecron CLI is fully standalone (pure bash, no runtime deps) and owns a
  local registry, prompts, per-host state, logs, and a launchd/systemd timer.
---

# claudecron

claudecron runs a prompt against an agent backend (Claude Code or Codex) on a
fixed wall-clock interval. Each scheduled task is a **loop**: an id, an
interval, a working directory, a least-privilege tool list, a backend, and a
self-contained prompt file. A local scheduler (launchd on macOS, systemd-user on
Linux) wakes a runner that executes every due, enabled loop.

Your job in this skill is to turn a fuzzy request like "check my open PRs every
15 minutes and ping me" into a correct `claudecron add` invocation with a
well-authored loop prompt.

## Golden rule: shell the CLI, never touch the files

The registry at `<CLAUDECRON_HOME>/registry.json` is the single source of truth
and is owned exclusively by the CLI. **Never** write, edit, or hand-merge
`registry.json`, `config.json`, or state files yourself. Every create / change /
query / delete goes through a `claudecron` subcommand. Hand-editing JSON will
desync state, corrupt the registry, and race the runner.

The CLI is standalone: pure bash that runs under macOS `/bin/bash` 3.2, no
external package manager, no network install. If `claudecron` is not on PATH,
tell the user to install it; do not attempt to fabricate the registry.

## Where things live

Resolution of the user data root `CLAUDECRON_HOME`, in order:
`$CLAUDECRON_HOME` -> `$XDG_CONFIG_HOME/claudecron` -> `~/.config/claudecron`
(fallback `~/.claudecron`).

- Registry (source of truth): `<CLAUDECRON_HOME>/registry.json` shape `{ "loops": [ ... ] }`
- Global config: `<CLAUDECRON_HOME>/config.json`
- Prompts: `<CLAUDECRON_HOME>/prompts/<id>.md`
- Per-host state: `<CLAUDECRON_HOME>/state/<hostname-s>/<id>.json`
- Logs: `<CLAUDECRON_HOME>/logs/runner.log` and `<CLAUDECRON_HOME>/logs/<id>.log`
- Scheduler unit basename: `dev.claudecron.runner`

Program code lives separately under `~/.local/share/claudecron/` (`bin/`,
`lib/`, `templates/`). You do not edit that either.

## Step 1 - gather intent

Before calling the CLI, pin down five things. Ask only for what is missing; infer
sensible defaults and confirm them.

1. **Task** - what should run each tick, in one sentence. ("Triage new review
   comments on my open PRs and notify me.")
2. **Interval** - how often, as `<N>m` minutes. Enforce a **one-minute floor**;
   if the user says "continuously" or gives nothing, propose a default like 15m
   and confirm. Sub-minute is not allowed.
3. **cwd** - the absolute project directory the loop operates in. If the user is
   in a repo, default to its root. The backend gets this as its working dir.
4. **backend** - `claude` (default) or `codex`. Use whatever the user already
   works in; if unstated, default to `claude`.
5. **tools** - the least-privilege set of tools the loop needs (see the table in
   `loop-prompt-guide.md`). Never hand a loop more than the task requires. A
   read-only digest loop should not get write or shell tools.

If any of these is ambiguous, ask one concise question rather than guessing on a
high-impact choice (cwd, tools, interval).

## Step 2 - author a good loop prompt

This is the part that matters most. A loop prompt is **not** a one-off prompt: it
runs unattended every tick, forever. Read `loop-prompt-guide.md` in this skill
directory and follow it exactly. The non-negotiables it enforces:

- **Cursor-not-clock.** The loop tracks a cursor (last-seen id / timestamp /
  sha) in its own state, never "things since I last woke up by clock time".
- **Mandatory cold-start branch.** On the very first run (no cursor yet), the
  loop records the current cursor, does nothing else, prints `noop`, and exits.
  This prevents a first-run flood (e.g. notifying on every historical PR).
- **Silence rule.** No new work since the cursor -> print `noop` and exit. Only
  act and notify when there is genuinely something new.
- **State split.** The loop owns ONLY its cursor / tracking file. It must NEVER
  write `last_run`, `last_status`, or `last_duration_s` - those belong to
  claudecron's runner state and are off-limits to the prompt.
- **Idempotency.** Check existence before any mutation (does this label / file /
  message already exist?) so a re-run never double-acts.

Write the prompt to a file in the scratch/working area (e.g.
`./loop-prompt.md`), then pass it with `--prompt-file`. claudecron copies it into
`<CLAUDECRON_HOME>/prompts/<id>.md`; you do not place it there yourself.

## Step 3 - create the loop

```bash
claudecron add <slug> \
  --interval <Nm> \
  --cwd <abs-dir> \
  --tools "<csv>" \
  --backend <claude|codex> \
  --prompt-file <file>
```

Example (read-mostly PR babysitter, every 15 minutes):

```bash
claudecron add pr-babysitter \
  --interval 15m \
  --cwd /home/octocat/work/hello-world \
  --tools "Bash,Read" \
  --backend claude \
  --prompt-file ./loop-prompt.md
```

The `--slug` becomes the loop id and must be a short kebab-case token. Good
example ids: `pr-babysitter`, `daily-digest`, `dep-watch`, `log-summarizer`,
`issue-groomer`.

On first `add`, claudecron may need to install its scheduler. If it reports the
timer is not installed, the user can opt in (the CLI gates this behind
`CLAUDECRON_INIT_SCHEDULER`); surface that, don't try to write the launchd plist
or systemd units yourself.

## Mapping requests to subcommands

| User says | Run |
|---|---|
| "run/schedule/loop X every N min" | `claudecron add <slug> --interval <Nm> --cwd <dir> --tools "<csv>" --backend <b> --prompt-file <file>` |
| "what loops do I have" / "how is X doing" / "status" | `claudecron status --json` |
| "pause X" / "stop X" (keep it) | `claudecron disable <id>` |
| "resume X" / "start X again" | `claudecron enable <id>` |
| "run X right now" | `claudecron run <id>` |
| "change X to every N min" / edit cwd/tools/prompt | `claudecron add <id> ...` again with the new flags (re-add updates) |
| "show me X's output / logs" | `claudecron logs <id>` |
| "delete X" / "remove X for good" | `claudecron remove <id> --purge --yes` |

Parse `claudecron status --json` to answer "how is X" - it carries each loop's
enabled flag, interval, last_run, last_status, and last_duration_s. Read those
from state via the CLI; never open the state JSON directly.

For destructive actions (`remove`, especially `--purge`), confirm the id with
the user first unless they were explicit. `--purge` also deletes the prompt,
state, and per-loop log for that id.

## Backend invocation (for reference)

You don't run these directly - the runner does - but knowing the contract helps
you pick the right `--tools`:

- claude: `"$BIN" -p "$PROMPT" --allowedTools "$TOOLS" --add-dir "$CWD" [--add-dir D]... --output-format text`
- codex: `"$BIN" exec "$PROMPT" --cd "$CWD" --sandbox workspace-write --ask-for-approval never`

For `codex` loops, tools are governed by the sandbox/approval surface rather
than a tool allowlist - see the `codex-claudecron` skill.

## Don't

- Don't write or edit `registry.json`, `config.json`, or any state file.
- Don't place prompt files into `<CLAUDECRON_HOME>/prompts/` yourself - pass
  `--prompt-file` and let the CLI copy.
- Don't grant tools beyond what the task needs.
- Don't author a loop prompt without the cold-start branch and silence rule.
- Don't set sub-minute intervals.

Copyright (c) 2026 The claudecron authors
