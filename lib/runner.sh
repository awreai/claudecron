#!/usr/bin/env bash
# Copyright (c) 2026 The claudecron authors
#
# lib/runner.sh - the run loop. Entry point cc_run handles both the user
# 'run' command and the scheduler '--wake' invocation.
#
# Flow:
#   1. acquire the lock (or quiet exit if another runner is live)
#   2. create the data tree, harden PATH
#   3. read the registry, iterate loops sequentially via portable while-read
#   4. per loop: skip if disabled (unless forced); compute due-ness (force
#      overrides); time the run; stream backend stdout+stderr to the loop log
#      (truncated to log_keep_lines); call cc_backend_exec; record state
#      (ok|error + duration); append due/skip/run/status lines to runner.log.
#   5. --dry-run prints the decision + resolved command and runs nothing.
#
# Depends on: common.sh, config.sh, state.sh, lock.sh, due.sh, backend.sh.

if [ -n "${CLAUDECRON_RUNNER_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDECRON_RUNNER_SOURCED=1

# runner__log <line> - append a structured line to runner.log (and stderr).
runner__log() {
  rl__line="$1"
  mkdir -p "$CLAUDECRON_LOGS_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(cc_now_iso)" "$rl__line" >> "$CLAUDECRON_RUNNER_LOG" 2>/dev/null || true
  unset rl__line
}

# runner__truncate_log <file> <keep> - keep only the last <keep> lines.
runner__truncate_log() {
  rt__file="$1"
  rt__keep="$2"
  case "$rt__keep" in
    ''|*[!0-9]* ) rt__keep=500 ;;
  esac
  [ -f "$rt__file" ] || { unset rt__file rt__keep; return 0; }
  rt__tmp="$rt__file.tmp.$$"
  if tail -n "$rt__keep" "$rt__file" > "$rt__tmp" 2>/dev/null; then
    mv -f "$rt__tmp" "$rt__file" 2>/dev/null || rm -f "$rt__tmp"
  else
    rm -f "$rt__tmp"
  fi
  unset rt__file rt__keep rt__tmp
  return 0
}

# runner__harden_path - prepend common tool dirs so launchd/systemd sparse
# environments still find jq and the backends.
runner__harden_path() {
  PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME:-}/.local/bin:${PATH:-}"
  export PATH
}

# runner__resolve_prompt <prompt_file_rel_or_abs> - print absolute prompt path.
runner__resolve_prompt() {
  rp__pf="$1"
  case "$rp__pf" in
    /* ) printf '%s\n' "$rp__pf" ;;
    *  ) printf '%s/%s\n' "$CLAUDECRON_HOME" "$rp__pf" ;;
  esac
  unset rp__pf
}

# runner__build_cmd_preview <backend> <bin> <tools> <cwd> <adddirs_nl>
#   Print a human-readable resolved command line (for --dry-run). add_dirs are
#   passed newline-separated in the 5th arg.
runner__build_cmd_preview() {
  bcp__backend="$1"; bcp__bin="$2"; bcp__tools="$3"; bcp__cwd="$4"; bcp__adddirs="$5"
  case "$bcp__backend" in
    claude )
      bcp__extra=""
      if [ -n "$bcp__adddirs" ]; then
        while IFS= read -r bcp__d; do
          [ -n "$bcp__d" ] || continue
          bcp__extra="$bcp__extra --add-dir '$bcp__d'"
        done <<EOF
$bcp__adddirs
EOF
      fi
      printf "%s -p '<prompt>' --allowedTools '%s' --add-dir '%s'%s --output-format text\n" \
        "$bcp__bin" "$bcp__tools" "$bcp__cwd" "$bcp__extra"
      ;;
    codex )
      printf "%s exec '<prompt>' --cd '%s' --sandbox workspace-write --ask-for-approval never\n" \
        "$bcp__bin" "$bcp__cwd"
      ;;
    * )
      printf '(unknown backend %s)\n' "$bcp__backend"
      ;;
  esac
  unset bcp__backend bcp__bin bcp__tools bcp__cwd bcp__adddirs bcp__extra bcp__d
}

# ---------------------------------------------------------------------------
# runner__run_one <loop-json> <force> <dry_run> <log_keep>
#   Process a single loop entry. Sequential; called from the iterate loop.
# ---------------------------------------------------------------------------
runner__run_one() {
  ro__json="$1"
  ro__force="$2"
  ro__dry="$3"
  ro__log_keep="$4"

  ro__id="$(printf '%s' "$ro__json" | cc_jq -r '.id')"
  ro__enabled="$(printf '%s' "$ro__json" | cc_jq -r '.enabled // true')"
  ro__interval="$(printf '%s' "$ro__json" | cc_jq -r '.interval_minutes // 15')"
  ro__cwd="$(printf '%s' "$ro__json" | cc_jq -r '.cwd // "."')"
  ro__tools="$(printf '%s' "$ro__json" | cc_jq -r '.allowed_tools // "Bash,Read"')"
  ro__prompt_file="$(printf '%s' "$ro__json" | cc_jq -r '.prompt_file // empty')"
  ro__backend="$(printf '%s' "$ro__json" | cc_jq -r '.backend // "claude"')"
  # add_dirs as newline-separated list.
  ro__adddirs="$(printf '%s' "$ro__json" | cc_jq -r '(.add_dirs // [])[]' 2>/dev/null)"

  [ -n "$ro__prompt_file" ] || ro__prompt_file="prompts/$ro__id.md"
  ro__prompt_path="$(runner__resolve_prompt "$ro__prompt_file")"
  ro__loop_log="$CLAUDECRON_LOGS_DIR/$ro__id.log"

  # Disabled gate (force overrides).
  if [ "$ro__enabled" != "true" ] && [ "$ro__force" != "1" ]; then
    runner__log "skip id=$ro__id reason=disabled"
    unset ro__json ro__force ro__dry ro__log_keep ro__id ro__enabled ro__interval ro__cwd ro__tools ro__prompt_file ro__backend ro__adddirs ro__prompt_path ro__loop_log
    return 0
  fi

  # Due-ness (force overrides).
  ro__last="$(state_last_run_epoch "$ro__id")"
  if [ "$ro__force" = "1" ]; then
    ro__is_due=0
    runner__log "due id=$ro__id forced=1"
  elif is_due "$ro__last" "$ro__interval"; then
    ro__is_due=0
    runner__log "due id=$ro__id last=${ro__last:-never} interval=${ro__interval}m"
  else
    ro__is_due=1
    runner__log "skip id=$ro__id reason=not-due last=${ro__last:-never} interval=${ro__interval}m"
  fi

  if [ "$ro__is_due" != "0" ]; then
    unset ro__json ro__force ro__dry ro__log_keep ro__id ro__enabled ro__interval ro__cwd ro__tools ro__prompt_file ro__backend ro__adddirs ro__prompt_path ro__loop_log ro__last ro__is_due
    return 0
  fi

  # --dry-run: print decision + resolved command, run nothing.
  if [ "$ro__dry" = "1" ]; then
    ro__bin_preview="$(resolve_backend_bin "$ro__backend" 2>/dev/null || printf '<%s-not-found>' "$ro__backend")"
    printf 'DRY-RUN loop=%s backend=%s cwd=%s prompt=%s\n' \
      "$ro__id" "$ro__backend" "$ro__cwd" "$ro__prompt_path" >&2
    printf '  command: ' >&2
    runner__build_cmd_preview "$ro__backend" "$ro__bin_preview" "$ro__tools" "$ro__cwd" "$ro__adddirs" >&2
    runner__log "dry-run id=$ro__id backend=$ro__backend"
    unset ro__json ro__force ro__dry ro__log_keep ro__id ro__enabled ro__interval ro__cwd ro__tools ro__prompt_file ro__backend ro__adddirs ro__prompt_path ro__loop_log ro__last ro__is_due ro__bin_preview
    return 0
  fi

  # Read the prompt.
  if [ ! -r "$ro__prompt_path" ]; then
    runner__log "status id=$ro__id result=error reason=prompt-missing path=$ro__prompt_path"
    state_record_run "$ro__id" error 0
    unset ro__json ro__force ro__dry ro__log_keep ro__id ro__enabled ro__interval ro__cwd ro__tools ro__prompt_file ro__backend ro__adddirs ro__prompt_path ro__loop_log ro__last ro__is_due
    return 0
  fi
  ro__prompt="$(cat "$ro__prompt_path")"

  runner__log "run id=$ro__id backend=$ro__backend cwd=$ro__cwd"

  # Rebuild add-dir positional args (3.2-safe, no arrays) by re-invoking the
  # backend exec with the newline list expanded into $@.
  ro__start="$(epoch_now)"

  # Run the backend, streaming combined stdout+stderr into the loop log.
  # We append; truncation happens afterward.
  {
    printf '%s ----- run start id=%s backend=%s -----\n' "$(cc_now_iso)" "$ro__id" "$ro__backend"
  } >> "$ro__loop_log" 2>/dev/null || true

  # Expand add_dirs into positionals without arrays: set -- inside a subshell
  # by reading the newline list. We pass them after the fixed four args.
  ro__rc=0
  if [ -n "$ro__adddirs" ]; then
    # Convert newline list to positional args using a here-doc fed loop into
    # a saved param string is unsafe with spaces; instead use a function that
    # reads them via 'set --' from a subshell-safe construct.
    runner__exec_with_adddirs "$ro__backend" "$ro__prompt" "$ro__tools" "$ro__cwd" "$ro__adddirs" \
      >> "$ro__loop_log" 2>&1
    ro__rc=$?
  else
    cc_backend_exec "$ro__backend" "$ro__prompt" "$ro__tools" "$ro__cwd" \
      >> "$ro__loop_log" 2>&1
    ro__rc=$?
  fi

  ro__end="$(epoch_now)"
  ro__dur=$(( ro__end - ro__start ))
  [ "$ro__dur" -ge 0 ] 2>/dev/null || ro__dur=0

  {
    printf '%s ----- run end id=%s rc=%s dur=%ss -----\n' "$(cc_now_iso)" "$ro__id" "$ro__rc" "$ro__dur"
  } >> "$ro__loop_log" 2>/dev/null || true

  # Truncate the loop log to log_keep_lines.
  runner__truncate_log "$ro__loop_log" "$ro__log_keep"

  if [ "$ro__rc" -eq 0 ]; then
    state_record_run "$ro__id" ok "$ro__dur"
    runner__log "status id=$ro__id result=ok dur=${ro__dur}s"
  else
    state_record_run "$ro__id" error "$ro__dur"
    runner__log "status id=$ro__id result=error rc=$ro__rc dur=${ro__dur}s"
  fi

  unset ro__json ro__force ro__dry ro__log_keep ro__id ro__enabled ro__interval ro__cwd ro__tools ro__prompt_file ro__backend ro__adddirs ro__prompt_path ro__loop_log ro__last ro__is_due ro__prompt ro__start ro__end ro__dur ro__rc
  return 0
}

# runner__exec_with_adddirs <backend> <prompt> <tools> <cwd> <adddirs_nl>
#   Expand the newline-separated add_dirs into positional args and call
#   cc_backend_exec. Kept separate so the 'set --' scope is contained.
runner__exec_with_adddirs() {
  ewa__backend="$1"; ewa__prompt="$2"; ewa__tools="$3"; ewa__cwd="$4"; ewa__adddirs="$5"
  # Seed positionals with the fixed four, then append each add-dir.
  set -- "$ewa__backend" "$ewa__prompt" "$ewa__tools" "$ewa__cwd"
  while IFS= read -r ewa__d; do
    [ -n "$ewa__d" ] || continue
    set -- "$@" "$ewa__d"
  done <<EOF
$ewa__adddirs
EOF
  cc_backend_exec "$@"
}

# ---------------------------------------------------------------------------
# cc_run [--wake] [--dry-run] [--force] [--id <id>]
#   --wake     : invoked by the scheduler (same path as 'run')
#   --dry-run  : print decisions + resolved commands, execute nothing
#   --force    : ignore enabled + due gating
#   --id <id>  : restrict to a single loop
# ---------------------------------------------------------------------------
cc_run() {
  cr__dry=0
  cr__force=0
  cr__only_id=""
  cr__wake=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wake )    cr__wake=1; shift ;;
      --dry-run ) cr__dry=1; shift ;;
      --force )   cr__force=1; shift ;;
      --id )      cr__only_id="$2"; shift 2 ;;
      -- )        shift; break ;;
      * )
        cc_err "cc_run: unknown argument '$1'"
        return 2
        ;;
    esac
  done

  # Lock first (quiet exit 0 if another runner holds it). Skip locking for a
  # pure dry-run so it never blocks on / steals an active run's lock.
  if [ "$cr__dry" != "1" ]; then
    lock_acquire
  fi

  cc_mkdirs
  registry_ensure
  config_ensure
  runner__harden_path

  cr__log_keep="$(cfg_get log_keep_lines 500)"

  if [ "$cr__wake" = "1" ]; then
    runner__log "wake source=scheduler host=$CLAUDECRON_HOST"
  else
    runner__log "wake source=cli host=$CLAUDECRON_HOST"
  fi

  # Iterate loops with portable while-read. Each loop entry is emitted as a
  # single compact JSON line by jq -c; we read line by line (no mapfile).
  cr__count=0
  while IFS= read -r cr__entry; do
    [ -n "$cr__entry" ] || continue
    if [ -n "$cr__only_id" ]; then
      cr__this_id="$(printf '%s' "$cr__entry" | cc_jq -r '.id')"
      [ "$cr__this_id" = "$cr__only_id" ] || continue
    fi
    cr__count=$(( cr__count + 1 ))
    runner__run_one "$cr__entry" "$cr__force" "$cr__dry" "$cr__log_keep"
  done <<EOF
$(registry_read | cc_jq -c '.loops[]')
EOF

  if [ -n "$cr__only_id" ] && [ "$cr__count" -eq 0 ]; then
    cc_err "no loop with id '$cr__only_id' in registry"
  fi

  runner__log "wake done host=$CLAUDECRON_HOST processed=$cr__count"
  unset cr__dry cr__force cr__only_id cr__wake cr__log_keep cr__count cr__entry cr__this_id
  return 0
}
