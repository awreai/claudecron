# Loop-prompt authoring guide (claudecron, Claude backend)

A loop prompt is the text claudecron feeds to the backend on **every tick,
unattended, forever**. It is fundamentally different from a one-shot prompt. A
bad loop prompt spams notifications, double-acts, or floods on first run. This
guide is the contract every loop prompt must satisfy.

Copyright (c) 2026 The claudecron authors

## The five laws

### 1. Cursor, not clock

Never reason about "what happened since I last ran" using wall-clock time. The
runner's schedule can drift, skip, or fire twice; the host can sleep. Instead the
loop maintains a **cursor**: the high-water mark of what it has already
processed - a last-seen id, an ISO timestamp, a commit sha, a max row id. Each
tick: read the cursor, find items strictly beyond it, process them, advance the
cursor. The cursor is the only thing that defines "new".

### 2. Mandatory cold-start branch

The first time a loop ever runs there is no cursor. If the loop treats
"everything" as new, it floods: notifying on every historical PR, re-summarizing
the entire backlog, etc. So the **first** thing every loop prompt does:

> If no cursor file exists: read the current high-water mark, write it as the
> cursor, take NO other action, print `noop`, and exit.

This seeds the cursor so that only things happening *after* setup are ever acted
on. There is no exception to this branch.

### 3. Silence rule

If, after consulting the cursor, there is nothing new: **print exactly `noop`
and exit.** Do not notify, do not summarize "nothing happened", do not write
files. A loop that runs every 15 minutes must be silent the vast majority of the
time. Noise on a quiet tick is a bug.

### 4. State split - own your cursor, nothing else

The loop owns ONE piece of state: its cursor / tracking data, stored in a file
**the loop chooses inside its own cwd or a path you give it** (e.g.
`./.loop-state/<id>.cursor`). The loop must **NEVER** write the keys `last_run`,
`last_status`, or `last_duration_s`, and must never touch claudecron's state
directory `<CLAUDECRON_HOME>/state/...`. Those fields are claudecron runner
bookkeeping. Mixing the two desyncs status reporting. Loop state and runner
state are strictly separate.

### 5. Idempotency - check before you mutate

Every side effect must be guarded by an existence check, because a tick can be
retried or overlap. Before creating a label, check it isn't already applied.
Before posting a message about item X, check the cursor already excludes X.
Before writing a digest file, check whether one for this window exists. A correct
loop can run twice on the same input and produce the same result with no
duplicate side effects.

## Least-privilege tools, by task

Grant the minimum. Map the task to the smallest tool set.

| Loop task | Typical tools (`--tools`) | Notes |
|---|---|---|
| Read-only digest / summary to stdout | `Read` | No shell, no write. |
| Summarize a log file on disk | `Read` | Point cwd at the dir; read the file. |
| Poll a repo's PRs/issues via CLI, notify | `Bash,Read` | Bash for the `gh`/API call; no Write. |
| Triage and label (mutating an external system) | `Bash,Read` | Mutation happens via the CLI tool, guarded by existence checks. |
| Generate/refresh a local artifact file | `Read,Write` | Write only the artifact path; no Bash unless needed. |
| Anything touching the working tree heavily | `Bash,Read,Write` | Last resort; justify each capability. |

Never add `Write` to a notify-only loop. Never add `Bash` to a loop that only
reads and emits text. Fewer tools = smaller blast radius on an unattended run.

## One-minute floor

The shortest legal interval is `1m`. Anything the user phrases as "constantly",
"in real time", or sub-minute must be clamped to `1m` and confirmed. Most loops
want 5m-60m. Long-poll-style work belongs at a sane cadence, not a tight spin.

## Copy-paste loop-prompt SKELETON

Fill the bracketed parts. This skeleton bakes in all five laws.

```
You are a claudecron loop. You run unattended on a fixed interval. Follow these
rules exactly and keep output minimal.

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
  Then [notify / write the artifact], once, summarizing only what is new.

STEP 4 - ADVANCE CURSOR:
  - Write the new high-water mark to ./.loop-state/<id>.cursor.
  - Print a one-line summary of what you did.

Never flood. On a quiet tick the correct behavior is a single line: noop.
```

## Two worked shapes (generic)

**PR triage loop.** Cursor = newest PR number already triaged. Cold start:
record the newest open PR number, print `noop`. Each tick: list open PRs with
number > cursor; for each, read it, and if it lacks a triage label, add one
(check the label isn't already there first); notify once with the list; advance
cursor. Tools: `Bash,Read`.

**Log-summary loop.** Cursor = byte offset or last-line timestamp already
summarized in a log file. Cold start: record current end-of-file, print `noop`.
Each tick: read only the portion after the cursor; if empty, `noop`; else write
(or append) a short summary to a digest file and advance the cursor. Tools:
`Read,Write` (or `Read` if summarizing to stdout only).

## Pre-ship checklist

Before you call `claudecron add`, verify the prompt:

- [ ] Has an explicit cursor file path the loop owns.
- [ ] Has a cold-start branch that records the cursor and prints `noop` with no
      other action.
- [ ] Prints `noop` and exits when there is nothing new (silence rule).
- [ ] Never writes `last_run` / `last_status` / `last_duration_s` and never
      touches claudecron's state dir (state split).
- [ ] Guards every mutation with an existence check (idempotent).
- [ ] Uses the least-privilege `--tools` for the task.
- [ ] Interval is >= 1m.
- [ ] Notifies/acts only on genuinely new items, once.
