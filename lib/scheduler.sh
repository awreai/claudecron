#!/usr/bin/env bash
# Copyright (c) 2026 The claudecron authors
#
# lib/scheduler.sh - install/verify/uninstall the periodic runner across
# launchd (macOS), systemd --user (Linux), or cron (fallback).
#
# Reverse-DNS label / unit basename: dev.claudecron.runner
#   launchd plist : ~/Library/LaunchAgents/dev.claudecron.runner.plist
#   systemd units : ${XDG_CONFIG_HOME:-~/.config}/systemd/user/
#                     dev.claudecron.runner.{service,timer}
#
# Templates live under <libexec>/templates/ and are rendered with sed token
# substitution. The runner is invoked as:  <bin>/claudecron run --wake
#
# Depends on: common.sh (paths, logging), config.sh (cfg_set_str at init).

if [ -n "${CLAUDECRON_SCHEDULER_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDECRON_SCHEDULER_SOURCED=1

CLAUDECRON_SCHED_LABEL="dev.claudecron.runner"
CLAUDECRON_LAUNCHD_PLIST="${HOME:-}/Library/LaunchAgents/${CLAUDECRON_SCHED_LABEL}.plist"
CLAUDECRON_SYSTEMD_DIR="${XDG_CONFIG_HOME:-${HOME:-}/.config}/systemd/user"
CLAUDECRON_SYSTEMD_SERVICE="${CLAUDECRON_SYSTEMD_DIR}/${CLAUDECRON_SCHED_LABEL}.service"
CLAUDECRON_SYSTEMD_TIMER="${CLAUDECRON_SYSTEMD_DIR}/${CLAUDECRON_SCHED_LABEL}.timer"
CLAUDECRON_CRON_MARKER_BEGIN="# >>> ${CLAUDECRON_SCHED_LABEL} >>>"
CLAUDECRON_CRON_MARKER_END="# <<< ${CLAUDECRON_SCHED_LABEL} <<<"

# Default wake cadence (minutes) when the scheduler ticks the runner. The
# runner itself decides per-loop due-ness, so a tight tick is fine.
CLAUDECRON_TICK_MINUTES="${CLAUDECRON_TICK_MINUTES:-1}"

# claudecron binary path (the dispatcher that accepts 'run --wake').
scheduler__bin_path() {
  if [ -x "$CLAUDECRON_PREFIX/bin/claudecron" ]; then
    printf '%s/bin/claudecron\n' "$CLAUDECRON_PREFIX"
  elif [ -x "$CLAUDECRON_LIBEXEC/bin/claudecron" ]; then
    printf '%s/bin/claudecron\n' "$CLAUDECRON_LIBEXEC"
  else
    cmd_path="$(command -v claudecron 2>/dev/null || true)"
    if [ -n "$cmd_path" ]; then
      printf '%s\n' "$cmd_path"
    else
      printf '%s/bin/claudecron\n' "$CLAUDECRON_LIBEXEC"
    fi
  fi
}

# ---------------------------------------------------------------------------
# detect_scheduler - choose a backend.
#   Darwin                                        -> launchd
#   Linux with a working 'systemctl --user'       -> systemd
#   else, if crontab present                      -> cron
#   else                                          -> none
# ---------------------------------------------------------------------------
detect_scheduler() {
  ds__os="$(uname -s 2>/dev/null || printf 'unknown')"
  case "$ds__os" in
    Darwin )
      printf 'launchd\n'
      unset ds__os
      return 0
      ;;
    Linux )
      if command -v systemctl >/dev/null 2>&1 \
         && systemctl --user show-environment >/dev/null 2>&1; then
        printf 'systemd\n'
        unset ds__os
        return 0
      fi
      ;;
  esac
  if command -v crontab >/dev/null 2>&1; then
    printf 'cron\n'
    unset ds__os
    return 0
  fi
  printf 'none\n'
  unset ds__os
  return 0
}

# ---------------------------------------------------------------------------
# resolve_path - a robust PATH for the scheduled context. Union of the login
# shell's PATH and known tool dirs, de-duplicated, order-preserving.
# ---------------------------------------------------------------------------
resolve_path() {
  rp__login="$("${SHELL:-/bin/bash}" -l -c 'printf %s "$PATH"' 2>/dev/null)"
  rp__known="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME:-}/.local/bin"
  rp__all="${rp__login}:${rp__known}"

  rp__out=""
  # Split on ':' without arrays.
  rp__rest="$rp__all"
  while [ -n "$rp__rest" ]; do
    case "$rp__rest" in
      *:* )
        rp__seg="${rp__rest%%:*}"
        rp__rest="${rp__rest#*:}"
        ;;
      * )
        rp__seg="$rp__rest"
        rp__rest=""
        ;;
    esac
    [ -n "$rp__seg" ] || continue
    # De-dup: skip if already present as a full segment.
    case ":$rp__out:" in
      *":$rp__seg:"* ) continue ;;
    esac
    if [ -z "$rp__out" ]; then
      rp__out="$rp__seg"
    else
      rp__out="$rp__out:$rp__seg"
    fi
  done

  printf '%s\n' "$rp__out"
  unset rp__login rp__known rp__all rp__out rp__rest rp__seg
}

# ---------------------------------------------------------------------------
# scheduler__render <template> <dest> - sed token substitution.
# Tokens: @@BIN@@ @@PATH@@ @@TICK_SECONDS@@ @@TICK_MINUTES@@ @@LABEL@@
#         @@HOME@@ @@LOG@@ @@CLAUDECRON_HOME@@
# Falls back to a built-in inline template if <template> is absent.
# ---------------------------------------------------------------------------
scheduler__render() {
  sr__tpl="$1"
  sr__dest="$2"
  sr__bin="$(scheduler__bin_path)"
  sr__path="$(resolve_path)"
  sr__tick_min="$CLAUDECRON_TICK_MINUTES"
  case "$sr__tick_min" in
    ''|*[!0-9]* ) sr__tick_min=1 ;;
  esac
  sr__tick_sec=$(( sr__tick_min * 60 ))
  [ "$sr__tick_sec" -ge 1 ] || sr__tick_sec=60
  sr__log="$CLAUDECRON_RUNNER_LOG"

  mkdir -p "$(dirname "$sr__dest")" 2>/dev/null || true

  if [ -r "$sr__tpl" ]; then
    sed \
      -e "s|@@BIN@@|$sr__bin|g" \
      -e "s|@@PATH@@|$sr__path|g" \
      -e "s|@@TICK_SECONDS@@|$sr__tick_sec|g" \
      -e "s|@@TICK_MINUTES@@|$sr__tick_min|g" \
      -e "s|@@LABEL@@|$CLAUDECRON_SCHED_LABEL|g" \
      -e "s|@@HOME@@|${HOME:-}|g" \
      -e "s|@@LOG@@|$sr__log|g" \
      -e "s|@@CLAUDECRON_HOME@@|$CLAUDECRON_HOME|g" \
      "$sr__tpl" > "$sr__dest"
  else
    scheduler__inline_template "$sr__tpl" "$sr__bin" "$sr__path" "$sr__tick_sec" "$sr__tick_min" "$sr__log" > "$sr__dest"
  fi
  unset sr__tpl sr__dest sr__bin sr__path sr__tick_min sr__tick_sec sr__log
}

# scheduler__inline_template <kind> <bin> <path> <tick_sec> <tick_min> <log>
#   <kind> is the template file path; we key off its basename to pick a body.
scheduler__inline_template() {
  it__kind="$1"; it__bin="$2"; it__path="$3"; it__tsec="$4"; it__tmin="$5"; it__log="$6"
  case "$it__kind" in
    *plist* )
      cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${CLAUDECRON_SCHED_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${it__bin}</string>
    <string>run</string>
    <string>--wake</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${it__path}</string>
    <key>CLAUDECRON_HOME</key>
    <string>${CLAUDECRON_HOME}</string>
  </dict>
  <key>StartInterval</key>
  <integer>${it__tsec}</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${it__log}</string>
  <key>StandardErrorPath</key>
  <string>${it__log}</string>
</dict>
</plist>
EOF
      ;;
    *service* )
      cat <<EOF
[Unit]
Description=claudecron runner (${CLAUDECRON_SCHED_LABEL})

[Service]
Type=oneshot
Environment=PATH=${it__path}
Environment=CLAUDECRON_HOME=${CLAUDECRON_HOME}
ExecStart=${it__bin} run --wake
EOF
      ;;
    *timer* )
      cat <<EOF
[Unit]
Description=claudecron runner timer (${CLAUDECRON_SCHED_LABEL})

[Timer]
OnBootSec=${it__tsec}
OnUnitActiveSec=${it__tsec}
AccuracySec=15
Persistent=true

[Install]
WantedBy=timers.target
EOF
      ;;
    * )
      # cron line.
      printf '*/%s * * * * %s run --wake >> %s 2>&1\n' "$it__tmin" "$it__bin" "$it__log"
      ;;
  esac
  unset it__kind it__bin it__path it__tsec it__tmin it__log
}

# scheduler__template_for <kind> - resolve a template path under templates/.
# kind in: plist, service, timer.
scheduler__template_for() {
  st__kind="$1"
  st__dir="$CLAUDECRON_LIBEXEC/templates"
  case "$st__kind" in
    plist )   printf '%s/dev.claudecron.runner.plist.tmpl\n' "$st__dir" ;;
    service ) printf '%s/dev.claudecron.runner.service.tmpl\n' "$st__dir" ;;
    timer )   printf '%s/dev.claudecron.runner.timer.tmpl\n' "$st__dir" ;;
    * )       printf '%s/%s.tmpl\n' "$st__dir" "$st__kind" ;;
  esac
  unset st__kind st__dir
}

# ---------------------------------------------------------------------------
# scheduler__init_config - record the resolved backend binaries into
# config.json (claude_bin / codex_bin) using command -v. Best-effort.
# ---------------------------------------------------------------------------
scheduler__init_config() {
  sic__claude="$(command -v claude 2>/dev/null || true)"
  sic__codex="$(command -v codex 2>/dev/null || true)"
  config_ensure || true
  [ -n "$sic__claude" ] && cfg_set_str claude_bin "$sic__claude" || true
  [ -n "$sic__codex" ]  && cfg_set_str codex_bin  "$sic__codex"  || true
  unset sic__claude sic__codex
  return 0
}

# ---------------------------------------------------------------------------
# launchd install / uninstall / verify
# ---------------------------------------------------------------------------
scheduler__install_launchd() {
  il__tpl="$(scheduler__template_for plist)"
  scheduler__render "$il__tpl" "$CLAUDECRON_LAUNCHD_PLIST"

  il__domain="gui/$(id -u)"
  il__target="${il__domain}/${CLAUDECRON_SCHED_LABEL}"

  # Idempotent: bootout any existing instance, then bootstrap fresh.
  launchctl bootout "$il__target" >/dev/null 2>&1 || true
  if launchctl bootstrap "$il__domain" "$CLAUDECRON_LAUNCHD_PLIST" >/dev/null 2>&1; then
    cc_log "launchd: bootstrapped $CLAUDECRON_SCHED_LABEL"
  else
    # Fallback to legacy load for older macOS.
    launchctl unload "$CLAUDECRON_LAUNCHD_PLIST" >/dev/null 2>&1 || true
    launchctl load "$CLAUDECRON_LAUNCHD_PLIST" >/dev/null 2>&1 || true
    cc_log "launchd: loaded $CLAUDECRON_SCHED_LABEL (legacy load path)"
  fi
  launchctl enable "$il__target" >/dev/null 2>&1 || true
  launchctl kickstart -k "$il__target" >/dev/null 2>&1 || true

  unset il__tpl il__domain il__target
  return 0
}

scheduler__uninstall_launchd() {
  ul__target="gui/$(id -u)/${CLAUDECRON_SCHED_LABEL}"
  launchctl bootout "$ul__target" >/dev/null 2>&1 || true
  launchctl unload "$CLAUDECRON_LAUNCHD_PLIST" >/dev/null 2>&1 || true
  rm -f "$CLAUDECRON_LAUNCHD_PLIST" 2>/dev/null || true
  cc_log "launchd: removed $CLAUDECRON_SCHED_LABEL"
  unset ul__target
  return 0
}

scheduler__verify_launchd() {
  if launchctl print "gui/$(id -u)/${CLAUDECRON_SCHED_LABEL}" >/dev/null 2>&1; then
    return 0
  fi
  launchctl list 2>/dev/null | grep -q "$CLAUDECRON_SCHED_LABEL"
}

# ---------------------------------------------------------------------------
# systemd install / uninstall / verify
# ---------------------------------------------------------------------------
scheduler__install_systemd() {
  is__svc_tpl="$(scheduler__template_for service)"
  is__tmr_tpl="$(scheduler__template_for timer)"
  scheduler__render "$is__svc_tpl" "$CLAUDECRON_SYSTEMD_SERVICE"
  scheduler__render "$is__tmr_tpl" "$CLAUDECRON_SYSTEMD_TIMER"

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now "${CLAUDECRON_SCHED_LABEL}.timer" >/dev/null 2>&1 || true
  # Survive logout so the timer keeps firing.
  loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
  cc_log "systemd: enabled ${CLAUDECRON_SCHED_LABEL}.timer"

  unset is__svc_tpl is__tmr_tpl
  return 0
}

scheduler__uninstall_systemd() {
  systemctl --user disable --now "${CLAUDECRON_SCHED_LABEL}.timer" >/dev/null 2>&1 || true
  systemctl --user stop "${CLAUDECRON_SCHED_LABEL}.service" >/dev/null 2>&1 || true
  rm -f "$CLAUDECRON_SYSTEMD_TIMER" "$CLAUDECRON_SYSTEMD_SERVICE" 2>/dev/null || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  cc_log "systemd: removed ${CLAUDECRON_SCHED_LABEL} units"
  return 0
}

scheduler__verify_systemd() {
  systemctl --user list-timers --all 2>/dev/null | grep -q "${CLAUDECRON_SCHED_LABEL}.timer" \
    || systemctl --user is-enabled "${CLAUDECRON_SCHED_LABEL}.timer" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# cron install / uninstall / verify (marker-block managed via awk)
# ---------------------------------------------------------------------------
scheduler__cron_line() {
  scl__bin="$(scheduler__bin_path)"
  scl__tick="$CLAUDECRON_TICK_MINUTES"
  case "$scl__tick" in
    ''|*[!0-9]* ) scl__tick=1 ;;
  esac
  printf 'PATH=%s\n' "$(resolve_path)"
  printf 'CLAUDECRON_HOME=%s\n' "$CLAUDECRON_HOME"
  printf '*/%s * * * * %s run --wake >> %s 2>&1\n' "$scl__tick" "$scl__bin" "$CLAUDECRON_RUNNER_LOG"
  unset scl__bin scl__tick
}

scheduler__install_cron() {
  ic__tmp="$CLAUDECRON_HOME/.crontab.$$"
  mkdir -p "$CLAUDECRON_HOME" 2>/dev/null || true

  # Strip any existing managed block, keep everything else.
  crontab -l 2>/dev/null | awk -v b="$CLAUDECRON_CRON_MARKER_BEGIN" -v e="$CLAUDECRON_CRON_MARKER_END" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    skip != 1 { print }
  ' > "$ic__tmp" 2>/dev/null || : > "$ic__tmp"

  {
    printf '%s\n' "$CLAUDECRON_CRON_MARKER_BEGIN"
    scheduler__cron_line
    printf '%s\n' "$CLAUDECRON_CRON_MARKER_END"
  } >> "$ic__tmp"

  if crontab "$ic__tmp" 2>/dev/null; then
    cc_log "cron: installed managed block for $CLAUDECRON_SCHED_LABEL"
  else
    cc_err "cron: failed to install crontab"
  fi
  rm -f "$ic__tmp" 2>/dev/null || true
  unset ic__tmp
  return 0
}

scheduler__uninstall_cron() {
  uc__tmp="$CLAUDECRON_HOME/.crontab.$$"
  crontab -l 2>/dev/null | awk -v b="$CLAUDECRON_CRON_MARKER_BEGIN" -v e="$CLAUDECRON_CRON_MARKER_END" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    skip != 1 { print }
  ' > "$uc__tmp" 2>/dev/null || : > "$uc__tmp"
  crontab "$uc__tmp" 2>/dev/null || true
  rm -f "$uc__tmp" 2>/dev/null || true
  cc_log "cron: removed managed block for $CLAUDECRON_SCHED_LABEL"
  unset uc__tmp
  return 0
}

scheduler__verify_cron() {
  crontab -l 2>/dev/null | grep -q "$CLAUDECRON_SCHED_LABEL"
}

# ---------------------------------------------------------------------------
# cc_install [backend] - install + load the scheduler idempotently.
# If no backend arg is given, auto-detect. Writes claude_bin/codex_bin at init.
# ---------------------------------------------------------------------------
cc_install() {
  ci__which="${1:-}"
  [ -n "$ci__which" ] || ci__which="$(detect_scheduler)"

  cc_mkdirs
  config_ensure
  scheduler__init_config

  case "$ci__which" in
    launchd ) scheduler__install_launchd ;;
    systemd ) scheduler__install_systemd ;;
    cron )    scheduler__install_cron ;;
    none )
      cc_err "no supported scheduler found (launchd/systemd/cron all unavailable)."
      cc_err "You can still run manually: claudecron run"
      unset ci__which
      return 1
      ;;
    * )
      cc_err "unknown scheduler '$ci__which'"
      unset ci__which
      return 2
      ;;
  esac

  if cc_verify "$ci__which"; then
    cc_log "scheduler '$ci__which' installed and verified"
  else
    cc_err "scheduler '$ci__which' installed but verification did not confirm it; check logs"
  fi
  unset ci__which
  return 0
}

# cc_verify [backend] - confirm the scheduler is registered. Returns 0/1.
cc_verify() {
  cv__which="${1:-}"
  [ -n "$cv__which" ] || cv__which="$(detect_scheduler)"
  case "$cv__which" in
    launchd ) scheduler__verify_launchd ;;
    systemd ) scheduler__verify_systemd ;;
    cron )    scheduler__verify_cron ;;
    * )       return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# cc_uninstall - tear down ALL THREE backends unconditionally (best-effort),
# so a machine that switched schedulers leaves nothing behind.
# ---------------------------------------------------------------------------
cc_uninstall() {
  # launchd (no-op off-Darwin / when launchctl absent).
  if command -v launchctl >/dev/null 2>&1; then
    scheduler__uninstall_launchd
  else
    rm -f "$CLAUDECRON_LAUNCHD_PLIST" 2>/dev/null || true
  fi

  # systemd (no-op when systemctl absent).
  if command -v systemctl >/dev/null 2>&1; then
    scheduler__uninstall_systemd
  else
    rm -f "$CLAUDECRON_SYSTEMD_TIMER" "$CLAUDECRON_SYSTEMD_SERVICE" 2>/dev/null || true
  fi

  # cron (no-op when crontab absent).
  if command -v crontab >/dev/null 2>&1; then
    scheduler__uninstall_cron
  fi

  cc_log "uninstalled scheduler from all backends"
  return 0
}
