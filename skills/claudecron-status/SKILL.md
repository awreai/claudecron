---
name: claudecron-status
description: >-
  Show the status and progress of claudecron background loops. Use when the user
  types /claudecron-status, asks "how are my loops doing", "show my claudecron
  loops", "what's my loop status", "did my loop run", "when does X run next", or
  wants a quick progress check on scheduled agent loops.
---

# /claudecron-status - quick loop progress

A thin wrapper over the `claudecron` CLI to show what is scheduled and how each
loop is doing. Run from a shell:

## What to do

1. Show the dashboard:

   ```
   claudecron status
   ```

   This prints a table: each loop's id, whether it is enabled, its interval,
   backend (claude/codex), last run time, last status (ok/error), and when it is
   next due.

2. If the user asks about a specific loop's recent activity, tail its log:

   ```
   claudecron logs <id> -n 30
   ```

3. If the user asks whether the scheduler itself is running:

   ```
   claudecron doctor
   ```

   Report the scheduler line (loaded / not loaded) and the last wake time.

4. If `claudecron` is not found on PATH, tell the user it is not installed and
   point them at the one-line install, then stop. Do not guess at status.

## Presenting results

- Summarize the table in plain language: how many loops, which are enabled, any
  with a last status of `error` (call those out first), and the next one due.
- For an `error` status, offer to show that loop's log so the user can see why.
- Keep it short. This is a status check, not a report.

## Notes

- Read-only. This skill never adds, edits, removes, enables, or disables a loop.
  For those, use the `claudecron` skill (or the CLI directly).
- The CLI is the source of truth; never read the registry/state files directly
  when the CLI can answer.
