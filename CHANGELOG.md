# Changelog

All notable changes to claudecron are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Built-in self-improve loop: seeded on init (every 2 days), audits and improves
  loop prompts with backup + five-laws validation; run on demand with
  `claudecron improve`.
- Interactive notification setup in `add` with an end-to-end test send; new
  `notify` config block; README "Notifications" section documenting Slack and
  channel overrides.
- `claudecron improve [--id <id>] [--dry-run]` subcommand to trigger a
  self-improve pass on demand without waiting for the scheduled run.
- Concurrent loop execution: due loops now run as bounded parallel processes
  (capped by `max_parallel`, default 4) so a slow loop does not delay others.
- Slack notification support: loops can notify via an agent Slack tool or via
  `Bash` + `curl` to a webhook; guided setup in `add` records the target and
  sends a test message to confirm delivery.

### Changed

### Fixed

## [0.1.0] - 2026-01-01

Initial release.

### Added

- `claudecron` CLI: `add`, `run` (with `--now` and `--wake`), `status`, `enable`, `disable`, and `scheduler install/status/uninstall`.
- Registry as the single source of truth at `<CLAUDECRON_HOME>/registry.json` with shape `{ "loops": [ ... ] }`; per-loop fields `id`, `enabled`, `interval_minutes`, `cwd`, `add_dirs`, `allowed_tools`, `prompt_file`, `backend`.
- Global config at `<CLAUDECRON_HOME>/config.json` (`backend`, `lock_stale_minutes`, `log_keep_lines`, `claude_bin`, `codex_bin`).
- `CLAUDECRON_HOME` resolution: `$CLAUDECRON_HOME` -> `$XDG_CONFIG_HOME/claudecron` -> `~/.config/claudecron`, with fallback `~/.claudecron`.
- Program/data split: program under `~/.local/share/claudecron/` (`bin/`, `lib/`, `templates/`); user data under `CLAUDECRON_HOME`.
- Catch-up-on-wake scheduling: a loop is due when elapsed time since its per-host cursor exceeds its interval; on wake a due loop runs once and the cursor jumps forward to cover the gap.
- Per-host state at `<CLAUDECRON_HOME>/state/<hostname>/<id>.json` so one registry can drive multiple machines independently.
- Two agent backends with a fixed invocation contract: `claude` (`-p ... --allowedTools ... --add-dir ... --output-format text`) and `codex` (`exec ... --cd ... --sandbox workspace-write --ask-for-approval never`).
- `CLAUDECRON_TEST_BACKEND_CMD` test seam: when set, the runner executes that command instead of a real backend, enabling token-free smoke tests.
- `mkdir`-based lock mutex at `<CLAUDECRON_HOME>/lock/` with stale-lock recovery governed by `lock_stale_minutes`.
- Logging: runner log at `<CLAUDECRON_HOME>/logs/runner.log` and per-loop logs at `<CLAUDECRON_HOME>/logs/<id>.log`, trimmed to `log_keep_lines`.
- Per-loop prompts as plain Markdown at `<CLAUDECRON_HOME>/prompts/<id>.md`.
- Opt-in OS scheduler integration under the basename `dev.claudecron.runner`: launchd plist at `~/Library/LaunchAgents/dev.claudecron.runner.plist` on macOS, and systemd user `service` + `timer` units under `${XDG_CONFIG_HOME:-~/.config}/systemd/user/` on Linux.
- Pure-bash implementation compatible with macOS `/bin/bash` 3.2: no `mapfile`/`readarray`, no `flock`, no associative arrays; guarded array expansions; BSD/GNU `date` detection.
- `curl | sh` installer with checksum-verified release tarball, no `sudo`, install under the user's home directory, and scheduler registration left opt-in.
- `scrub-check` and token-free `smoke-test` scripts for local and CI verification.

[Unreleased]: https://example.com/claudecron/compare/v0.1.0...HEAD
[0.1.0]: https://example.com/claudecron/releases/tag/v0.1.0
