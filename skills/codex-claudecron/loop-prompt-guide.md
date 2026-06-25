# Loop-prompt authoring guide (claudecron, Codex backend)

A loop prompt is the text claudecron feeds to Codex on **every tick,
unattended, forever**. It is fundamentally different from a one-shot prompt. A
bad loop prompt spams notifications, double-acts, or floods on first run. Under
Codex this is sharper: the runner invokes
`codex exec "$PROMPT" --cd "$CWD" --sandbox workspace-write --ask-for-approval never`,
so there is no human approval gate and the workspace is write-enabled. **The
prompt is the privilege boundary.** This guide is the contract every loop prompt
must satisfy.

Copyright (c) 2026 The claudecron authors

## The five laws

### 1. Cursor, not clock

Never reason about "what happened since I last ran" using wall-clock time. The
schedule can drift, skip, or fire twice; the host can sleep. Instead the loop
maintains a **cursor**: the high-water mark of what it has already processed - a
last-seen id, an ISO timestamp, a commit sha, a max row id. Each tick: read the
cursor, find items strictly beyond it, process them, advance the cursor. The
cursor is the only definition of "new".

### 2. Mandatory cold-start branch

The first time a loop ever runs there is no cursor. If it treats "everything" as
new, it floods. So the **first** thing every loop prompt does:

> If no cursor file exists: read the current high-water mark, write it as the
> cursor, take NO other action, print `noop`, and exit.

This seeds the cursor so only things happening *after* setup are ever acted on.
No exceptions.

### 3. Silence rule

If, after consulting the cursor, there is nothing new: **print exactly `noop`
and exit.** Do not notify, do not summarize "nothing happened", do not write
files. A loop on a 15-minute interval is silent the vast majority of the time.
Noise on a quiet tick is a bug.

### 4. State split - own your cursor, nothing else

The loop owns ONE piece of state: its cursor / tracking data, in a file the loop
chooses inside its own cwd (e.g. `./.loop-state/<id>.cursor`). The loop must
**NEVER** write the keys `last_run`, `last_status`, or `last_duration_s`, and
must never touch claudecron's state directory `<CLAUDECRON_HOME>/state/...`.
Those are claudecron runner bookkeeping. Loop state and runner state are
strictly separate.

### 5. Idempotency - check before you mutate

Every side effect must be guarded by an existence check, because a tick can be
retried or overlap - and under Codex there is no approval gate to stop a
double-action. Before creating a label, check it isn't already applied. Before
posting about item X, check the cursor already excludes X. Before writing a
digest file, check whether one for this window exists. A correct loop can run
twice on the same input and produce the same result with no duplicate effects.

## Privilege under Codex - scope by prompt

Codex has no per-tool allowlist. It runs with `--sandbox workspace-write` and
`--ask-for-approval never`, so it can read/write inside the workspace and run
commands without prompting. Compensate in the prompt:

| Loop task | What the prompt must say |
|---|---|
| Read-only digest / summary | State explicitly: read only, make NO writes, emit the summary to stdout. |
| Summarize a log file | Read only the named file under cwd; write nothing except (optionally) the named digest file. |
| Poll a repo's PRs/issues, notify | Run only the specific read command; the only write is the single notification. |
| Triage / label external system | Name the exact mutation and guard it with an existence check; do nothing else. |
| Generate/refresh a local artifact | Name the single artifact path; write only that file. |

The rule: enumerate the allowed actions in the prompt and forbid everything
else. Confine all paths to the cwd. The tighter the prompt, the smaller the
blast radius of an unattended write-enabled run.

## One-minute floor

The shortest legal interval is `1m`. Anything phrased as "constantly", "in real
time", or sub-minute is clamped to `1m` and confirmed. Most loops want 5m-60m.

## Copy-paste loop-prompt SKELETON

Fill the bracketed parts. This skeleton bakes in all five laws and the
Codex-specific scoping.

```
You are a claudecron loop running under Codex (workspace-write sandbox, no
approval prompts). You run unattended on a fixed interval. Do ONLY the actions
listed below; make no other writes and run no other commands. Keep all paths
inside the current working directory. Keep output minimal.

CURSOR FILE: ./.loop-state/<id>.cursor
This file holds the high-water mark of what you have already processed
( [e.g. the newest PR number seen / newest comment id / latest commit sha] ).
This is the ONLY state you own. Never write last_run, last_status, or
last_duration_s, and never touch claudecron's state directory.

STEP 1 - COLD START:
  If ./.loop-state/<id>.cursor does NOT exist:
    - Read the current high-water mark from [the source].
    - Write it to the cursor file (create ./.loop-state/ if needed).
    - Do nothing else. Print exactly: noop
    - Exit.

STEP 2 - FIND NEW WORK:
  - Read the cursor.
  - Query [the source] for items strictly newer than the cursor.
  - If there are none: print exactly: noop  and exit.

STEP 3 - ACT (only if there is new work):
  For each new item, oldest first:
    - Before any side effect, check it has not already been done
      (label not already present / message not already posted / file absent).
    - Do the task: [one precise sentence of what to do per item].
  Then [notify / write the named artifact], once, summarizing only what is new.

STEP 4 - ADVANCE CURSOR:
  - Write the new high-water mark to ./.loop-state/<id>.cursor.
  - Print a one-line summary of what you did.

Allowed actions: [enumerate them]. Do nothing outside this list.
Never flood. On a quiet tick the correct behavior is a single line: noop.
```

## Two worked shapes (generic)

**PR triage loop.** Cursor = newest PR number already triaged. Cold start:
record the newest open PR number, print `noop`. Each tick: list open PRs with
number > cursor; for each, read it, and if it lacks a triage label add one
(check the label isn't already there first); notify once with the list; advance
cursor. Prompt scope: only the list/read/label commands and the one
notification.

**Log-summary loop.** Cursor = byte offset or last-line timestamp already
summarized. Cold start: record current end-of-file, print `noop`. Each tick:
read only the portion after the cursor; if empty, `noop`; else write (or append)
a short summary to the named digest file and advance the cursor. Prompt scope:
read the log, write only the digest file.

## Pre-ship checklist

Before you call `claudecron add --backend codex`, verify the prompt:

- [ ] Has an explicit cursor file path the loop owns, inside the cwd.
- [ ] Has a cold-start branch that records the cursor and prints `noop` with no
      other action.
- [ ] Prints `noop` and exits when there is nothing new (silence rule).
- [ ] Never writes `last_run` / `last_status` / `last_duration_s` and never
      touches claudecron's state dir (state split).
- [ ] Guards every mutation with an existence check (idempotent).
- [ ] Enumerates allowed actions and forbids everything else (Codex has no
      approval gate).
- [ ] Confines all paths to the cwd.
- [ ] Interval is >= 1m.
- [ ] Notifies/acts only on genuinely new items, once.
