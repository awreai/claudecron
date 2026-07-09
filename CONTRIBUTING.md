# Contributing to claudecron

Thanks for helping. `claudecron` is a small, auditable program with a few hard invariants. Most of this document is those invariants - break one and the build will (rightly) reject the change.

## Ground rules

- Keep it minimal. Add only what the change asks for; if a feature needs new surface area, open an issue first.
- Logs over comments. Wherever behavior could surprise someone reading `runner.log`, log it.
- No emoticons anywhere in code or logs.
- Use a single hyphen in prose. Never an en-dash or em-dash.

## Portability: one stdlib-only Python file, no dependencies

The runner is a single Python 3 file at `bin/claudecron`. Keep it that way:

- **Standard library only.** No third-party packages, no `pip install`, no virtualenv. The whole point is that `python3` (which macOS and mainstream Linux both ship) is the only requirement. If you reach for a dependency, you have taken a wrong turn.
- **Python 3.6+.** That is the floor. Avoid features newer than 3.6 (for example, do not rely on `str.removeprefix`, which is 3.9). When in doubt, test under an older interpreter.
- **One file.** Do not split the runner into a package. The single-file property is what makes it trivial to read, audit, vendor, and ship in a tarball. Helper scripts under `scripts/` and the `claudecron-notify` helper are the only other executables.
- **Cross-platform by branching, not assuming.** macOS (launchd) and Linux (systemd user timers) are both supported. Detect the platform and branch; never hardcode one scheduler's paths or `date` flavor.
- **The `install.sh` and uninstall scripts stay POSIX `sh`.** They must run before Python is even confirmed present (they check for it), so keep them dependency-free shell.

If you are unsure whether something works on an older Python, test it before sending the change.

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
./scripts/scrub-check.sh
./scripts/smoke-test.sh
./scripts/regression-test.sh
```

- **scrub-check** - scans the tree for anything that must never ship: personal names, internal hostnames, real Slack/Discord IDs, absolute paths from a developer machine, vendor-internal labels. Examples in docs must use only the generic placeholders: repo `octocat/hello-world`, user `octocat`, email `you@example.com`, channel `<CHANNEL_ID>`. The scheduler basename must be `dev.claudecron.runner` and nothing else. If scrub-check fails, fix the leak; do not weaken the check. Note: it scans the working tree only, not git history - keep commit author identities clean at commit time.
- **smoke-test** - runs a full init -> add -> run --now cycle against `CLAUDECRON_TEST_BACKEND_CMD`, asserting on lock behavior, cursor advancement, and per-host state. Token-free by construction.
- **regression-test** - the behavioral suite: disabled-loop skipping, stdin isolation, lock stealing/liveness, the failure hook and notifier coalescing, timeout kills, model resolution, and self-improve seeding. If you touched scheduling, locking, state, notifications, or the runner, this is the proof it still works.

## Pull requests

- One logical change per PR. Keep diffs small and reviewable.
- Update README and CHANGELOG when behavior or flags change.
- Include the smoke-test output (or a CI link) for anything touching the runner.
- No attribution trailers in commits or PR bodies.

## Release checklist

Releases are tagged tarballs with a published checksum, consumed by the `curl | sh` installer and the Homebrew tap.

1. **Bump the version.** Update the `VERSION` file (and the pinned `DEFAULT_VERSION` in `install.sh` / the Homebrew formula) and the `CHANGELOG.md` Unreleased section: move entries under a new dated version heading.
2. **Tag.** Create an annotated git tag for the version (for example `v0.1.0`) and push it.
3. **Build the tarball + checksum.** Produce the release tarball and a `sha256` checksum file beside it. The checksum is what the installer verifies, so it must match the published artifact exactly.
4. **Cut the Release.** Publish a GitHub Release for the tag, attaching the tarball and its `.sha256`. Paste the relevant CHANGELOG section as the release notes.
5. **Bump the Homebrew tap.** Update the formula in the `homebrew-tap` repo to point at the new tarball URL and the new `sha256`. Verify a clean `brew install` from the tap on a fresh machine.
6. **Smoke the installer.** On a clean machine, run the pinned `curl | sh` install, confirm checksum verification passes, and run the quickstart (`add` -> `run --now` -> `status`).

That is it. Small surface, strong invariants, token-free tests. Welcome aboard.
