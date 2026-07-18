# claudecron

**Cron for headless AI coding agents.** Tell Claude Code or Codex to do a job on a schedule - "triage my PRs every 15 minutes", "summarize the error log every hour" - and it just happens, locally, on your machine, indefinitely. No server, no inbound surface, no cloud middleman, no session left open.

`claudecron` is a tiny, auditable supervisor that sits between your OS scheduler and a headless agent (`claude` or `codex`). You describe the work in plain English to your agent; `claudecron` runs it on a cadence and reports back only when it matters.

- **Talk to your agent, not a config file.** The installer wires skills into Claude Code and Codex. You say what you want; the skill writes the loop and registers it. (There is a full CLI underneath if you prefer - see below.)
- **Local-first and least-privilege.** Every loop declares exactly which tools the agent may use and which directories it may touch. Nothing runs that you did not approve.
- **Survives sleep.** If your laptop was asleep when a loop was due, `claudecron` runs it once on wake and moves on. One catch-up run, not a storm of missed ticks.
- **One small file, zero dependencies.** A single self-contained Python 3 script - no daemon, no packages to install, MIT licensed. You only pay your own agent usage.

---

## Do you even need this? (honest comparison)

Claude Code now ships its own scheduling, and for a lot of jobs that is the right answer. Reach for the built-ins first:

| You want to... | Use |
|---|---|
| Poll something for a while *during a session* (a deploy, a PR) | Claude Code [`/loop`](https://code.claude.com/docs/en/scheduled-tasks) |
| A durable local schedule, Claude backend, no terminal open | Claude Code [Desktop scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks) |
| A managed schedule that runs even with your machine off | Claude Code [Routines](https://code.claude.com/docs/en/routines) (cloud) |

`claudecron` exists for the cases those do not cover:

- **Codex too, not just Claude.** The built-ins are Claude-only. `claudecron` runs `claude` *or* `codex` behind the same registry, chosen per loop.
- **Local, unattended, and unbounded.** `/loop` is session-scoped, has **no catch-up for missed fires**, and expires after 7 days. `claudecron` runs from your OS scheduler with no session, catches up once on wake, and never expires.
- **Sub-hour cadence with nothing in the cloud.** Cloud Routines have a **1-hour minimum** and run in a fresh clone with no access to your local files. `claudecron` goes down to 1-minute intervals, entirely on your machine, against your real working tree.
- **Per-loop least privilege as a first-class field.** Each loop pins its own `allowed_tools` and `add_dirs`. There is no implicit "all tools" mode.
- **Plain files you own.** Registry, prompts, config, state, and logs are all diffable text under your home directory. One registry can drive several machines, each with its own cursor.

If none of those matter to you, use the built-ins. If several do, that is the gap this fills.

---

## Quickstart - talk to your agent

**1. Install (one line - sets up the scheduler and wires the skills into Claude Code + Codex):**

```sh
curl -fsSL https://raw.githubusercontent.com/awreai/claudecron/main/install.sh | sh
```

The only requirement is `python3` (macOS and mainstream Linux both ship it).

**2. Open Claude Code (or Codex) and just say what you want:**

> "Every 15 minutes, look at open PRs on octocat/hello-world and label the ones that need review. Don't merge anything."

The `claudecron` skill takes it from there - it picks a sensible interval, scopes the tools to least privilege, writes a self-contained loop prompt, and registers the loop for you. You can talk to it the same way to manage loops:

> "How are my loops doing?" &nbsp;&rarr;&nbsp; runs the `/claudecron-status` skill
> "Pause the PR one." &nbsp;&rarr;&nbsp; disables it
> "Delete the log summarizer and its history." &nbsp;&rarr;&nbsp; removes it

That is the whole experience: **install once, then talk to your agent.** Your loops run on their intervals from then on - even with no terminal open.

### Prefer the CLI? (power users)

Everything the skills do is just the `claudecron` CLI, which is fully standalone (no agent required to drive it):

```sh
claudecron add pr-babysitter \
  --interval 15m \
  --cwd ~/code/hello-world \
  --tools "Bash,Read,Grep" \
  --prompt "Check open PRs on octocat/hello-world and label what needs review. Never merge."

claudecron run --now pr-babysitter   # test it immediately, no waiting
claudecron status                    # dashboard of every loop
claudecron logs pr-babysitter -f     # follow a loop's output
```

Two scheduling styles: `--interval 15m` (elapsed time since last run) or `--at 07:00` (daily anchor, 24h local time). An anchored loop runs once per day at or after its time; a missed day catches up with one run, same as intervals. `--at ""` on a re-add clears the anchor.

The CLI is the contract; the skills only call into it. Delete every skill and `claudecron` keeps working identically.

---

## How it works

`claudecron` does not poll and does not stay resident. Your OS scheduler (launchd on macOS, a systemd user timer on Linux) wakes it on a fixed cadence. On each wake it reads the registry, decides which loops are due, and runs each due loop's prompt against its backend.

```
  +---------------------+
  |   OS scheduler      |   launchd  /  systemd user timer
  |  dev.claudecron.    |   fires on an interval
  |     runner          |
  +----------+----------+
             |  claudecron run --wake
             v
  +---------------------+        reads
  |     claudecron      | -----------------------+
  |  (single Python 3   |                        |
  |   file, stdlib only)|                        v
  +----------+----------+            +---------------------+
             |                       |   registry.json     |
             | for each DUE loop     |   { "loops": [...] } |
             |                       +----------+----------+
             |                                  |
             |   per-loop prompt  <-------------+  prompts/<id>.md
             v
  +---------------------+
  |   backend           |   claude  -p ... --allowedTools ... --add-dir ...
  |  (claude | codex)   |   codex   exec ... --cd ... --sandbox workspace-write
  +----------+----------+
             |  writes
             v
  +---------------------+
  |  state/ + logs/     |   state/<host>/<id>.json   (last run, cursor)
  |  (per host)         |   logs/<id>.log, runner.log
  +---------------------+
```

The runner takes a lock so two wakes can never overlap, and each due loop runs under its own per-loop lock so a slow loop never blocks the others. Each loop has its own log; the runner has its own log; state is written per host so one registry can drive several machines independently.

### Catch-up on wake (the sleep story)

Real laptops sleep. A loop due every 15 minutes will miss ticks while the lid is closed. `claudecron` does not try to replay every missed tick. Each loop's state file holds a **cursor** - the last time it ran. On wake, a loop is "due" if more than its interval has elapsed since the cursor. If it is due, it runs **once** and the cursor jumps to now.

So: laptop sleeps for six hours, wakes, your 15-minute loop runs exactly once, and the cursor covers the entire gap. No backlog, no burst of six hours of runs, no duplicate work. The next tick proceeds normally from the new cursor.

---

## Backends

`claudecron` shells out to a headless agent. You pick the backend per install (in `config.json`) or per loop, and `claudecron` builds the exact invocation:

| Backend  | Invocation (conceptual)                                                                   | Sandbox / approvals               |
|----------|-------------------------------------------------------------------------------------------|-----------------------------------|
| `claude` | `claude -p "<prompt>" --allowedTools "<tools>" --add-dir "<cwd>" [--add-dir <dir>]... [--model <m>] --output-format text` | Tools gated by `allowed_tools`; dirs gated by `add_dirs` |
| `codex`  | `codex exec "<prompt>" --cd "<cwd>" --sandbox workspace-write --ask-for-approval never`     | Workspace-write sandbox, no interactive approval |
| `exec`   | `/bin/sh -c "<prompt>"` - the prompt IS the command line; no agent, no tokens               | Whatever the command itself does; `tools`/`model` ignored |

The `exec` backend turns a loop into a plain scheduled command with claudecron's locking, state, logs, catch-up, and failure notifications. Use it for deterministic glue (pollers, heartbeats) sitting next to agent loops.

The backend binary is auto-detected, or you can pin it with `claude_bin` / `codex_bin` in `config.json`.

**Model selection (claude).** A loop's own `model` field wins, then config `default_model`, then a built-in default. Pin one per loop with `claudecron add <id> --model <name>`; an explicit empty model omits `--model` and lets the CLI choose. `codex` ignores the model field.

**Test seam.** Set `CLAUDECRON_TEST_BACKEND_CMD` and `claudecron` runs that command instead of a real backend. This lets you smoke-test scheduling, locking, state, and logging end to end without spending a single token. CI uses exactly this.

---

## Notifications and failures

Loops notify you through their own granted tools - give a loop a Slack or webhook tool and write "post a summary to #ops" into its prompt, and only that loop can reach that channel.

Separately, `claudecron` ships a **failure notifier** so a broken loop is never silent. On `init` it wires `claudecron-notify` as the default `on_failure_cmd`: any non-zero loop run fires a local, backend-independent alert (macOS notification, `notify-send` on Linux, or a log fallback). It coalesces noise - a repeated failure of the same loop is suppressed within a cooldown, and a systemic outage that fails *every* loop at once (an auth or quota problem, say) collapses into a single alert instead of one per loop. Point `on_failure_cmd` at your own script to route failures anywhere.

---

## Self-improving loops (opt-in)

`init` seeds a built-in `self-improve` loop, **disabled by default**. When you enable it (`claudecron enable self-improve`), every couple of days it audits your *other* loops' prompts and run logs and rewrites prompts that have drifted - a loop that acts on quiet ticks, one that keeps erroring, one that lost its cold-start guard. Every rewrite is backed up first and must pass a validation gate before it is applied through the normal CLI path; it never hand-edits the registry.

You can also run one pass on demand without enabling anything scheduled:

```sh
claudecron improve                      # audit + improve all loops, once
claudecron improve --id pr-babysitter   # focus the audit on one loop
claudecron improve --dry-run            # show what would run, invoke nothing
```

It is off by default on purpose: an agent that edits its own configuration should be something you turn on deliberately, not a surprise on a fresh install.

---

## Where things live

`claudecron` separates the **program** (read-only, replaceable on upgrade) from your **data** (the registry, prompts, config, state, logs).

Program (libexec):

```
~/.local/share/claudecron/
  bin/         the claudecron entrypoint (a single Python file) + claudecron-notify
  skills/      agent skills wired into Claude Code / Codex
  builtins/    shipped loop prompts (e.g. self-improve)
```

Your data (`CLAUDECRON_HOME`), resolved in this order:
`$CLAUDECRON_HOME` -> `$XDG_CONFIG_HOME/claudecron` -> `~/.config/claudecron` (fallback `~/.claudecron`):

```
<CLAUDECRON_HOME>/
  registry.json              source of truth: { "loops": [ ... ] }
  config.json                global config
  prompts/<id>.md            one prompt per loop
  state/<hostname>/<id>.json  per-host run state and cursor
  logs/runner.log            the runner's own log
  logs/<id>.log              per-loop output
  lock/                      run lock
```

### Registry entry

Each loop in `registry.json` looks like this:

```json
{
  "id": "pr-babysitter",
  "enabled": true,
  "interval_minutes": 15,
  "cwd": "/abs/path/to/hello-world",
  "add_dirs": ["/abs/path/to/extra"],
  "allowed_tools": "Bash,Read,Grep",
  "prompt_file": "prompts/pr-babysitter.md",
  "backend": "claude"
}
```

An optional `"model"` field pins the claude model for that loop.

### Global config

```json
{
  "backend": "claude",
  "default_model": "",
  "lock_stale_minutes": 30,
  "log_keep_lines": 500,
  "claude_bin": "",
  "codex_bin": "",
  "on_failure_cmd": ""
}
```

---

## Scheduler

The OS scheduler integration is **opt-in**. Installing the CLI does not register anything with launchd or systemd until you ask:

```sh
claudecron scheduler install     # registers the timer for your user
claudecron scheduler status
claudecron scheduler uninstall   # removes it
```

The scheduler label/unit basename is `dev.claudecron.runner`:

- **macOS (launchd):** `~/Library/LaunchAgents/dev.claudecron.runner.plist`
- **Linux (systemd user):** `${XDG_CONFIG_HOME:-~/.config}/systemd/user/dev.claudecron.runner.service` and `.timer`

The scheduler invokes `claudecron run --wake`, which is the catch-up entrypoint described above.

---

## The skills and commands

The installer wires `claudecron` into whichever agents it finds, so you manage
everything in plain language. Two skills ship for Claude Code, one prompt for Codex:

| Where | Installed at | What it does |
|-------|--------------|--------------|
| Claude Code | `~/.claude/skills/claudecron` | Create and manage loops. Triggers on "run X every N minutes", "schedule this", "set up a loop", "stop/delete the X loop". |
| Claude Code | `~/.claude/skills/claudecron-status` | The `/claudecron-status` command - a quick read-only progress check. Triggers on "how are my loops doing", "did X run", "when is X next due". |
| Codex | `~/.codex/prompts/claudecron.md` | The same create-and-manage flow, defaulting to the `codex` backend. |

**Create a loop** - describe the job, the agent does the rest:

> "Watch package.json for outdated dependencies once a day and write a summary to DEPENDENCY_UPDATES.md."

The skill picks the interval, scopes tools to least privilege, writes a
self-contained loop prompt (with a cursor and a silence-when-nothing-changed
rule), and registers it.

**Check progress** - type the command or just ask:

> `/claudecron-status` &nbsp; or &nbsp; "how are my loops doing?"

summarizes what is scheduled, what last ran, anything that errored, and what is due next.

**Manage** - all conversational:

> "Pause the dependency watcher." &rarr; disables it
> "Run the PR triage right now." &rarr; runs it once immediately
> "Delete the log summarizer and its history." &rarr; removes it with state

You can also drive the integration directly:

```sh
claudecron skills install   # wire into Claude Code + Codex (init does this for you)
claudecron skills status    # show where the skills are installed
claudecron skills remove    # unwire (claudecron uninstall does this too)
```

**The CLI is the contract; skills only call into it.** Everything above maps to a
`claudecron` command, the CLI is fully standalone, and you can skip the skills
entirely with `claudecron init --no-skills`.

---

## Security model

`claudecron` is deliberately small and inspectable.

- **Least privilege per loop.** A loop can only use the tools listed in `allowed_tools` and only touch `cwd` plus `add_dirs`. There is no implicit "all tools" mode.
- **Runs locally, as you.** Loops run on your machine under your user account with your environment. There is no daemon running as root and no privilege escalation.
- **You own the prompts.** Prompts are plain Markdown files in your `CLAUDECRON_HOME`. Nothing is fetched at runtime; what you wrote is what runs.
- **No inbound surface.** `claudecron` opens no ports and accepts no connections. It is a scheduled local process, not a service. Nothing on the network can trigger it.
- **Auditable state.** Registry, config, prompts, state, and logs are all plain files you can read, diff, and version-control.

### A note on `curl | sh`

Piping an installer to a shell deserves caution. So:

- **Read it first.** The install script is short and human-readable; open the URL in a browser before you run it.
- **Pin a tag.** Install a specific released version rather than a moving `latest`.
- **Checksum-verified.** The installer downloads a release tarball and verifies its `sha256` against the published checksum before unpacking.
- **No sudo.** Everything installs under your home directory (`~/.local/share/claudecron` and `CLAUDECRON_HOME`). The installer never asks for root.
- **Scheduler is opt-in.** Installation does not touch launchd or systemd. You run `claudecron scheduler install` explicitly, or never.

---

## FAQ

**What does it cost to run?**
Nothing to `claudecron` itself - it is local and free. You pay for your own agent usage (your `claude` or `codex` account/credits) exactly as if you had run the agent by hand. `claudecron` just decides *when*.

**Does it need a server?**
No. There is no backend service, no account, no hosted control plane. It is a single Python script your OS scheduler runs locally.

**Do I need to keep a terminal or Claude Code session open?**
No. Unlike a session-scoped `/loop`, `claudecron` runs from your OS scheduler with nothing open, and its loops do not expire.

**How do I stop a loop?**
Disable it (`claudecron disable <id>`, or set `"enabled": false` in the registry) to keep the definition but stop running it. To stop everything, `claudecron scheduler uninstall`. To remove the program entirely, delete `~/.local/share/claudecron` and, if you want, your `CLAUDECRON_HOME`.

**Does it run while my laptop is asleep?**
No - nothing runs while the machine is asleep. On wake, any loop that became due during the sleep runs **once** and its cursor jumps forward to cover the gap. See [Catch-up on wake](#catch-up-on-wake-the-sleep-story).

**Can one registry drive several machines?**
Yes. State is stored per host (`state/<hostname>/<id>.json`), so each machine keeps its own cursor while sharing the same registry and prompts.

**Which OSes are supported?**
macOS (launchd) and Linux (systemd user timers) for scheduling. The runner itself is a single Python 3 script (>= 3.6) and needs no other dependencies.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The headline rules: the runner stays a single stdlib-only Python file, the CLI stays standalone, and you run the scrub-check plus the token-free smoke and regression tests before you push.

## License

See [LICENSE](LICENSE). Copyright (c) 2026 The claudecron authors.
