# Self-improving loops + notification channel - Design

Status: Approved (design phase)

## Summary

Two related capabilities for claudecron:

1. **Self-improvement** - claudecron ships a built-in `self-improve` loop that is
   registered by default on `init`, runs every 2 days, audits every loop (its
   prompt + recent run log), and improves the loop prompts: tightening noise,
   fixing missed cases, repairing errors. It can also be triggered manually. It
   auto-applies improvements, backs up the prior prompt first, validates the
   rewrite still satisfies the five loop laws, and notifies the user. It audits
   all loops including itself.

2. **Notification setup** - claudecron has no built-in notion of Slack;
   notification is something a loop prompt does by calling a tool in its
   allowlist. This feature adds an interactive setup step so `claudecron add`
   asks how the loop should notify (Slack channel, webhook, or none), performs a
   real end-to-end test send, and confirms it works before finishing. The README
   documents the Slack integration and how to override the comm channel.

The CLI stays standalone and bash 3.2 portable. All JSON via `cc_jq`. The
backend is invoked through the existing `cc_backend_exec` contract - no new
execution path.

## Part 1 - Self-improvement

### Surface

- **Default loop on install.** `cmd_init` seeds a `self-improve` registry entry
  (interval 2880m = 2 days, enabled) pointing at a shipped builtin prompt. Seeded
  idempotently - never clobbers an existing entry. Like config/registry, the seed
  is skipped if the loop already exists, so upgrades and re-inits are safe.
- **Manual trigger.** `claudecron improve [--id <loop>] [--dry-run]` runs one
  self-improve pass immediately (equivalent to the scheduled pass). `--id`
  restricts to one target loop; `--dry-run` reports proposed changes without
  writing. This is a thin wrapper over the same builtin prompt path the runner
  uses, so behavior is identical scheduled vs manual.

### Builtin prompt

- Lives in the program tree (shipped with the tool), not the user data dir, so
  upgrades refresh it: `builtins/self-improve.prompt.md`. On `init` it is copied
  to `prompts/self-improve.md` in the data dir (the registry entry points there),
  matching how every other loop resolves its prompt.
- The prompt is itself a well-formed loop prompt (five laws): cursor file under
  the per-host state dir, mandatory cold-start branch, silence rule, owns only
  its cursor, idempotent.

### What the self-improve pass does

1. **Preflight / cold start.** On first run (no cursor), record a baseline hash
   per loop of (prompt content + tail of its log), print `noop`, exit. This
   prevents a first-run rewrite storm.
2. **Find work.** For each loop in the registry, compute a current hash of
   (prompt + recent log tail). A loop is a candidate only if its hash changed
   since the cursor (its behavior or prompt moved) - cursor, not clock. If
   nothing changed: `noop`.
3. **Audit each candidate.** Read the loop's prompt and the tail of its log
   (`<CLAUDECRON_HOME>/logs/<id>.log`). Assess: is it noisy (acting on quiet
   ticks, missing the silence rule), does it miss cases (errors in the log it
   does not handle), is it erroring (non-zero runs, repeated failures), did it
   drift from the five laws.
4. **Improve.** Produce a rewritten prompt that fixes the findings while keeping
   behavior intent. Before applying:
   - **Backup.** Copy the current prompt to
     `<CLAUDECRON_HOME>/prompts/.backups/<id>.<timestamp>.md`.
   - **Validation gate.** The rewrite must still contain the structural markers
     of the five laws (cold-start branch, silence rule / `noop`, a state/cursor
     clause, an idempotency guard). If any is missing, REJECT the rewrite - do
     not apply it, only report it. This makes auto-apply safe: mechanical
     improvements land, but a rewrite that would gut a loop's safety skeleton is
     refused.
   - **Apply** via the sanctioned path: write the new prompt file, then
     `loop_upsert` the (unchanged-field) entry so the registry stays the source
     of truth. Never hand-edit registry.json.
5. **Self-edit last, minimal.** When the candidate is `self-improve` itself,
   make the smallest viable change and keep all five laws verbatim. Prevents a
   runaway that weakens its own audit logic each pass.
6. **Notify.** Send ONE notification summarizing per loop: what was noisy / missed
   / errored, what changed, and the backup path (so a regression is one `cp` to
   revert). Uses the configured notify channel (Part 2). If nothing was applied
   and nothing needs attention: stay silent.
7. **Advance cursor.** Record the new per-loop hashes. Drop entries for removed
   loops.

### Safety

- Auto-apply is gated by: mandatory pre-write backup + the five-laws validation
  gate + self-edit-minimal rule. A rejected rewrite is reported, never applied.
- The pass never touches `last_run` / `last_status` / `last_duration_s` or the
  claudecron state dir beyond its own cursor file.
- Runs in the user's configured backend via `cc_backend_exec`; tools limited to
  what the audit needs (Bash, Read, Write, plus the notify tool).

## Part 2 - Notification channel

### How notification works today (documented, not changed)

claudecron does not send messages itself. A loop notifies by calling a tool in
its `allowed_tools` - e.g. a Slack MCP tool, or `Bash` running `curl` to a
webhook. The channel/target lives in the loop prompt. This is the convention the
example loops follow.

### Interactive setup + end-to-end test (new)

`claudecron add` gains an interactive notify step (also offered when adding a
loop that will notify). It asks:

- **How should this loop notify you?** Options: Slack (channel id + the tool to
  use), webhook (URL), command (a shell line), or none.
- It then records the answer into the loop's prompt scaffold (channel id / URL)
  so the authored prompt has a concrete target, and into config for reuse as the
  default for future loops.
- **Test send.** It performs a real notification ("claudecron test from loop
  <id>") through the chosen channel and asks the user to confirm they received
  it. If the send fails or the user says they did not see it, setup reports the
  failure and how to fix it rather than silently finishing. Verification before
  completion - the user knows notifications work end to end before the loop ever
  fires unattended.

### Override

The comm channel is overridable at three levels, documented in the README:

1. Per loop - edit the channel id / URL in the loop's prompt (the authored
   target), or re-run `add` for that loop and answer the notify step again.
2. Default for new loops - a `notify` block in config.json (channel kind +
   target + tool) used as the prefilled default during `add`.
3. Per environment - environment variables the prompt reads (e.g. a channel id
   override) for users who run the same loop across machines.

### README

A new "Notifications" section documents: that loops notify via a tool in their
allowlist; the Slack path (MCP tool or webhook) end to end; the interactive
setup and test; and the three override levels above. Cross-linked from
Quickstart and the Registry/Config sections.

## Integration points (from the codebase map)

- `bin/claudecron`: dispatch table (~line 1117) gains `improve)`; new
  `cmd_improve()`; `usage()` (~line 104) documents it; `cmd_init` (~line 253,
  after `loop_registry_init`) seeds the default self-improve loop; `cmd_add`
  gains the interactive notify step + test.
- New `builtins/self-improve.prompt.md` shipped in the program tree; copied to
  the data dir on init (installer + `skills_install`-adjacent staging).
- `lib/config.sh`: a `notify` default block + getters, consistent with
  `cfg_get` / `cfg_set`.
- Reuse: `loop_get`, `loop_upsert`, `runner__resolve_prompt`, `state_*`,
  `cc_backend_exec`, `cc_jq`. No new JSON handling.
- Tests: extend `scripts/smoke-test.sh` for `improve --dry-run` and the seeded
  default loop; keep token-free via `CLAUDECRON_TEST_BACKEND_CMD`. `scrub-check`
  must pass (no personal data in builtins/docs).
- Docs: README "Notifications" section + a short `improve` entry under commands;
  update CHANGELOG; add a skill note so agents know the feature exists.

## Constraints

- Bash 3.2 portable; no mapfile/flock/associative arrays.
- CLI standalone; skills call the CLI, not vice versa.
- Backend contract exact; all JSON via `cc_jq`.
- Commit identity: the repo's existing neutral identity (public OSS).
- **Loops never write artifacts into the repo they operate on.** A loop's
  prompt, design notes, cursor/state, backups, and logs all live under the
  claudecron home (`<CLAUDECRON_HOME>`, e.g. `~/.config/claudecron` or
  `~/.claudecron`), never in the target `cwd`. A loop is infrastructure, not
  project content - keeping its files out of the app repo prevents loop cruft
  accumulating in every repo a loop touches, and keeps the loop's history
  separate from the app's. The self-improve cursor, prompt backups, and any
  authored notes default to paths under the claudecron home. The README states
  this explicitly.

## Out of scope (later)

- A general plugin system for arbitrary notifiers.
- Cross-loop learning (one loop's fix informing another).
- Rollback automation (backups exist; revert is manual `cp` for now).
