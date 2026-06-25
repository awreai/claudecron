# Contributing to claudecron

Thanks for helping. `claudecron` is a small, auditable bash program with a few hard invariants. Most of this document is those invariants - break one and the build will (rightly) reject the change.

## Ground rules

- Keep it minimal. Add only what the change asks for; if a feature needs new surface area, open an issue first.
- Logs over comments. Wherever behavior could surprise someone reading `runner.log`, log it.
- No emoticons anywhere in code or logs.
- Use a single hyphen in prose. Never an en-dash or em-dash.

## Portability: bash 3.2, no exceptions

Everything must run under macOS `/bin/bash` (version 3.2) as well as modern Linux bash. macOS ships 3.2 and that is the floor. This rules out a number of conveniences you may reach for by habit:

- **No `mapfile` / `readarray`.** They do not exist in 3.2. Read into arrays with a `while read` loop instead.
- **No `flock`.** It is not portable (and not on macOS). Use a `mkdir`-based mutex - `mkdir` is atomic, and a failed `mkdir` means the lock is held.
- **No associative arrays (`declare -A`).** Not supported in 3.2. Use indexed arrays, or parallel arrays, or parse JSON on demand.
- **Guard every array expansion under `set -u`.** A bare `"${arr[@]}"` on an empty array errors under `set -u` in bash 3.2. Always write `${arr[@]+"${arr[@]}"}`.
- **Detect the `date` flavor.** BSD `date` (macOS) uses `date -j`; GNU `date` (Linux) uses `date -d`. Branch on which one is present; never assume one.
- **No GNU-only flags** on `sed`, `grep`, `stat`, etc. If you need `stat`, branch BSD vs GNU. Prefer POSIX-portable invocations.

If you are unsure whether something is 3.2-safe, test it under `/bin/bash` on a Mac before sending the change.

## Invariant: the CLI stays standalone

The `claudecron` command must be fully usable on its own - `add`, `run`, `run --now`, `run --wake`, `status`, `enable`/`disable`, `scheduler install/uninstall`, all driven by `registry.json` and prompt files. Skills, editor integrations, and any other wrappers are **sugar that calls into the CLI**. They may never become a requirement. A reviewer will reject any change that makes core behavior depend on a skill or external helper. Test: if you deleted every wrapper, `claudecron` must still do everything from the shell.

## Invariant: the state split

There is a strict separation between:

- **Definition** - `registry.json`, `config.json`, and `prompts/<id>.md`. This is the source of truth, portable across machines, safe to commit.
- **Per-host state** - `state/<hostname>/<id>.json`, holding the run cursor and last-run info.

State is written **per host** so one registry can drive several machines, each with its own cursor. Do not write run state into the registry, and do not read scheduling cursors from anywhere but the per-host state file. The catch-up-on-wake logic depends on this: a loop is due when `now - cursor >= interval`, the cursor jumps to `now` on run, and that is the only place the cursor lives. Keep definition and state on opposite sides of that line.

## The backend contract

Backends are invoked exactly as specified - do not improvise flags:

```
claude:  "$BIN" -p "$PROMPT" --allowedTools "$TOOLS" --add-dir "$CWD" [--add-dir D]... --output-format text
codex:   "$BIN" exec "$PROMPT" --cd "$CWD" --sandbox workspace-write --ask-for-approval never
```

If `CLAUDECRON_TEST_BACKEND_CMD` is set, run **that** command instead of a real backend. All tests must go through this seam so the suite never spends tokens.

## Before you push

Run both of these locally. CI runs them too, but catching it yourself is faster:

```sh
make scrub-check    # or: ./scripts/scrub-check.sh
make smoke-test     # or: ./scripts/smoke-test.sh
```

- **scrub-check** - greps the tree for anything that must never ship: personal names, internal hostnames, real Slack/Discord IDs, absolute paths from a developer machine, vendor-internal labels. Examples in docs must use only the generic placeholders: repo `octocat/hello-world`, user `octocat`, email `you@example.com`, channel `<CHANNEL_ID>`. The scheduler basename must be `dev.claudecron.runner` and nothing else. If scrub-check fails, fix the leak; do not weaken the check.
- **smoke-test** - runs a full add -> run --now -> run --wake -> status cycle against `CLAUDECRON_TEST_BACKEND_CMD`, asserting on lock behavior, cursor advancement, and per-host state. Token-free by construction. If you touched scheduling, locking, state, or logging, the smoke test is the proof it still works.

## Pull requests

- One logical change per PR. Keep diffs small and reviewable.
- Update README and CHANGELOG when behavior or flags change.
- Include the smoke-test output (or a CI link) for anything touching the runner.
- No attribution trailers in commits or PR bodies.

## Release checklist

Releases are tagged tarballs with a published checksum, consumed by the `curl | sh` installer and the Homebrew tap.

1. **Bump the version.** Update `CLAUDECRON_VERSION` and the `CHANGELOG.md` Unreleased section: move entries under a new dated version heading.
2. **Tag.** Create an annotated git tag for the version (for example `v0.1.0`) and push it.
3. **Build the tarball + checksum.** Produce the release tarball and a `sha256` checksum file beside it. The checksum is what the installer verifies, so it must match the published artifact exactly.
4. **Cut the Release.** Publish a GitHub Release for the tag, attaching the tarball and its `.sha256`. Paste the relevant CHANGELOG section as the release notes.
5. **Bump the Homebrew tap.** Update the formula in the `homebrew-tap` repo to point at the new tarball URL and the new `sha256`. Verify a clean `brew install` from the tap on a fresh machine.
6. **Smoke the installer.** On a clean machine, run the pinned `curl | sh` install, confirm checksum verification passes, and run the quickstart (`add` -> `run --now` -> `status`).

That is it. Small surface, strong invariants, token-free tests. Welcome aboard.
