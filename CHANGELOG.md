# Changelog

All notable changes to claudecron are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Single-file, stdlib-only Python 3 runner (`bin/claudecron`), replacing the
  original bash implementation. Same on-disk formats (registry, config, per-host
  state), same CLI surface, same `dev.claudecron.runner` scheduler label and
  `run --wake` entrypoint, and the same backend invocation strings, so it is a
  drop-in replacement: existing loops, state, and the installed timer keep working.
- Per-loop model selection for the `claude` backend: a loop's `model` field wins,
  then config `default_model`, then a built-in default. `claudecron add <id>
  --model <name>` pins one; an explicit empty model omits `--model`.
- Failure notifier: `init` wires `claudecron-notify` as the default
  `on_failure_cmd`. Any non-zero loop run fires a local, backend-independent
  alert (macOS notification / `notify-send` / log fallback). Repeated failures of
  the same loop are coalesced within a cooldown, and a systemic outage that fails
  every loop at once collapses into a single alert.
- Per-loop locks so a slow loop no longer blocks the rest of a pass; a per-run
  timeout; and a run lock that checks for a live holder and never steals from a
  running pid.
- Built-in `self-improve` loop, seeded on `init` but **disabled by default**, plus
  a `claudecron improve [--id <loop>] [--dry-run]` command to run one audit-and-
  improve pass on demand.
- `claudecron doctor` and richer `init` (scaffold config, wire the failure
  notifier, seed builtins, install skills, optionally register the scheduler).

### Changed

- Re-adding a loop (`add <id> --force`) now preserves `interval`, `cwd`,
  `add_dirs`, `allowed_tools`, `backend`, `model`, and `enabled` when the
  corresponding flag is omitted, instead of resetting them to defaults. This makes
  `add <id> --prompt-file X` a safe in-place prompt update.
- The installer and Homebrew formula now require `python3` and ship `bin/`,
  `skills/`, and `builtins/` (no more `lib/` or `templates/`).

### Fixed

- Four core scheduling bugs from the bash runner, carried into and verified on the
  Python runner: disabled loops were still run; a stdin-reading backend could
  starve later loops in the same pass; config-merge silently discarded overrides;
  and error status was swallowed inside functions.

## [0.1.0] - 2026-06-25

Initial release. Pure-bash implementation (later superseded by the Python runner;
see Unreleased).

### Added

- `claudecron` CLI: `add`, `run` (with `--now` and `--wake`), `status`, `enable`, `disable`, and `scheduler install/status/uninstall`.
- Registry as the single source of truth at `<CLAUDECRON_HOME>/registry.json` with shape `{ "loops": [ ... ] }`; per-loop fields `id`, `enabled`, `interval_minutes`, `cwd`, `add_dirs`, `allowed_tools`, `prompt_file`, `backend`.
- Global config at `<CLAUDECRON_HOME>/config.json` (`backend`, `lock_stale_minutes`, `log_keep_lines`, `claude_bin`, `codex_bin`).
- `CLAUDECRON_HOME` resolution: `$CLAUDECRON_HOME` -> `$XDG_CONFIG_HOME/claudecron` -> `~/.config/claudecron`, with fallback `~/.claudecron`.
- Program/data split: program under `~/.local/share/claudecron/`; user data under `CLAUDECRON_HOME`.
- Catch-up-on-wake scheduling: a loop is due when elapsed time since its per-host cursor exceeds its interval; on wake a due loop runs once and the cursor jumps forward to cover the gap.
- Per-host state at `<CLAUDECRON_HOME>/state/<hostname>/<id>.json` so one registry can drive multiple machines independently.
- Two agent backends with a fixed invocation contract: `claude` (`-p ... --allowedTools ... --add-dir ... --output-format text`) and `codex` (`exec ... --cd ... --sandbox workspace-write --ask-for-approval never`).
- `CLAUDECRON_TEST_BACKEND_CMD` test seam: when set, the runner executes that command instead of a real backend, enabling token-free smoke tests.
- Run lock at `<CLAUDECRON_HOME>/lock/` with stale-lock recovery governed by `lock_stale_minutes`.
- Logging: runner log at `<CLAUDECRON_HOME>/logs/runner.log` and per-loop logs at `<CLAUDECRON_HOME>/logs/<id>.log`, trimmed to `log_keep_lines`.
- Per-loop prompts as plain Markdown at `<CLAUDECRON_HOME>/prompts/<id>.md`.
- Opt-in OS scheduler integration under the basename `dev.claudecron.runner`: launchd plist at `~/Library/LaunchAgents/dev.claudecron.runner.plist` on macOS, and systemd user `service` + `timer` units under `${XDG_CONFIG_HOME:-~/.config}/systemd/user/` on Linux.
- `curl | sh` installer with checksum-verified release tarball, no `sudo`, install under the user's home directory, and scheduler registration left opt-in.
- `scrub-check` and token-free `smoke-test` scripts for local and CI verification.

[Unreleased]: https://github.com/awreai/claudecron/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/awreai/claudecron/releases/tag/v0.1.0
