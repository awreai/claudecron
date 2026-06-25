#!/usr/bin/env bash
# Copyright (c) 2026 The claudecron authors
#
# lib/config.sh - read/write config.json and registry.json atomically.
#
# Depends on lib/common.sh (cc_jq, cc_mkdirs, paths, logging).
#
# config.json shape:
#   { "backend": "claude", "lock_stale_minutes": 30, "log_keep_lines": 500,
#     "claude_bin": "", "codex_bin": "" }
#
# registry.json shape:
#   { "loops": [ { "id": "...", "enabled": true, "interval_minutes": 15,
#       "cwd": "...", "add_dirs": ["..."], "allowed_tools": "Bash,Read,...",
#       "prompt_file": "prompts/<id>.md", "backend": "claude" } ] }

if [ -n "${CLAUDECRON_CONFIG_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDECRON_CONFIG_SOURCED=1

# Defaults (single source of truth).
CLAUDECRON_DEFAULT_BACKEND="claude"
CLAUDECRON_DEFAULT_LOCK_STALE_MINUTES=30
CLAUDECRON_DEFAULT_LOG_KEEP_LINES=500
CLAUDECRON_DEFAULT_INTERVAL_MINUTES=15
CLAUDECRON_DEFAULT_ALLOWED_TOOLS="Bash,Read"

# ---------------------------------------------------------------------------
# cc__atomic_write_stdin <dest> - write stdin to dest atomically (temp + mv).
# ---------------------------------------------------------------------------
cc__atomic_write_stdin() {
  cc__aw_dest="$1"
  cc__aw_dir="$(dirname "$cc__aw_dest")"
  mkdir -p "$cc__aw_dir" 2>/dev/null || true
  cc__aw_tmp="$cc__aw_dest.tmp.$$"
  cat > "$cc__aw_tmp" || { rm -f "$cc__aw_tmp"; return 1; }
  mv -f "$cc__aw_tmp" "$cc__aw_dest" || { rm -f "$cc__aw_tmp"; return 1; }
  unset cc__aw_dest cc__aw_dir cc__aw_tmp
  return 0
}

# ---------------------------------------------------------------------------
# config: default injection.
# config_default_json - emit the canonical default config to stdout.
# ---------------------------------------------------------------------------
config_default_json() {
  cc_jq -n \
    --arg backend "$CLAUDECRON_DEFAULT_BACKEND" \
    --argjson lock_stale "$CLAUDECRON_DEFAULT_LOCK_STALE_MINUTES" \
    --argjson log_keep "$CLAUDECRON_DEFAULT_LOG_KEEP_LINES" \
    '{ backend: $backend, lock_stale_minutes: $lock_stale, log_keep_lines: $log_keep, claude_bin: "", codex_bin: "" }'
}

# config_ensure - create config.json with defaults if it does not exist.
config_ensure() {
  cc_mkdirs || return 1
  if [ ! -f "$CLAUDECRON_CONFIG" ]; then
    config_default_json | cc__atomic_write_stdin "$CLAUDECRON_CONFIG" || return 1
    cc_log "created default config at $CLAUDECRON_CONFIG"
  fi
  return 0
}

# config_read - emit config.json merged over defaults (fills missing keys).
config_read() {
  if [ -f "$CLAUDECRON_CONFIG" ]; then
    config_default_json | cc_jq -s '.[0] * (input // {})' - "$CLAUDECRON_CONFIG" 2>/dev/null \
      || config_default_json
  else
    config_default_json
  fi
}

# cfg_get <key> [default] - print one scalar config value.
cfg_get() {
  cfg__key="$1"
  cfg__def="${2:-}"
  cfg__val="$(config_read | cc_jq -r --arg k "$cfg__key" '.[$k] // empty' 2>/dev/null)"
  if [ -z "$cfg__val" ]; then
    printf '%s\n' "$cfg__def"
  else
    printf '%s\n' "$cfg__val"
  fi
  unset cfg__key cfg__def cfg__val
}

# cfg_set <key> <json-value> - set one config key (value is a JSON literal).
# Strings must be quoted by the caller, e.g. cfg_set backend '"claude"'.
cfg_set() {
  config_ensure || return 1
  cfg__k="$1"
  cfg__v="$2"
  config_read | cc_jq --arg k "$cfg__k" --argjson v "$cfg__v" '.[$k] = $v' \
    | cc__atomic_write_stdin "$CLAUDECRON_CONFIG" || return 1
  unset cfg__k cfg__v
  return 0
}

# cfg_set_str <key> <string> - convenience setter for string values.
cfg_set_str() {
  config_ensure || return 1
  cfg__k="$1"
  cfg__s="$2"
  config_read | cc_jq --arg k "$cfg__k" --arg s "$cfg__s" '.[$k] = $s' \
    | cc__atomic_write_stdin "$CLAUDECRON_CONFIG" || return 1
  unset cfg__k cfg__s
  return 0
}

# ---------------------------------------------------------------------------
# registry helpers.
# ---------------------------------------------------------------------------

# registry_ensure - create registry.json with { "loops": [] } if absent.
registry_ensure() {
  cc_mkdirs || return 1
  if [ ! -f "$CLAUDECRON_REGISTRY" ]; then
    printf '%s\n' '{ "loops": [] }' | cc_jq '.' | cc__atomic_write_stdin "$CLAUDECRON_REGISTRY" || return 1
    cc_log "created empty registry at $CLAUDECRON_REGISTRY"
  fi
  return 0
}

# registry_read - emit normalized registry to stdout (always { loops: [...] }).
registry_read() {
  if [ -f "$CLAUDECRON_REGISTRY" ]; then
    cc_jq '{ loops: (.loops // []) }' "$CLAUDECRON_REGISTRY" 2>/dev/null \
      || printf '%s\n' '{ "loops": [] }'
  else
    printf '%s\n' '{ "loops": [] }'
  fi
}

# registry_ids - print loop ids, one per line.
registry_ids() {
  registry_read | cc_jq -r '.loops[].id'
}

# ---------------------------------------------------------------------------
# id validation: ^[a-z0-9-]+$
# ---------------------------------------------------------------------------
validate_id() {
  vid__id="$1"
  case "$vid__id" in
    '' )
      cc_err "loop id may not be empty"
      unset vid__id
      return 1
      ;;
  esac
  # Reject any character outside [a-z0-9-].
  case "$vid__id" in
    *[!a-z0-9-]* )
      cc_err "invalid loop id '$vid__id' (allowed: lowercase letters, digits, hyphen)"
      unset vid__id
      return 1
      ;;
  esac
  unset vid__id
  return 0
}

# ---------------------------------------------------------------------------
# interval parser: 15m->15, 2h->120, 90->90; reject sub-minute.
# Accepts: <N>, <N>m, <N>min, <N>h, <N>hr. Prints minutes (integer) on stdout.
# Returns non-zero and prints nothing valid on bad input or sub-minute.
# ---------------------------------------------------------------------------
parse_interval() {
  pi__raw="$1"
  pi__num=""
  pi__unit=""
  case "$pi__raw" in
    '' )
      cc_err "empty interval"
      unset pi__raw pi__num pi__unit
      return 1
      ;;
  esac

  # Extract numeric prefix.
  pi__num="$(printf '%s' "$pi__raw" | sed -n 's/^\([0-9][0-9]*\).*$/\1/p')"
  # Extract unit suffix (lowercased).
  pi__unit="$(printf '%s' "$pi__raw" | sed -n 's/^[0-9][0-9]*//p' | tr 'A-Z' 'a-z')"

  if [ -z "$pi__num" ]; then
    cc_err "invalid interval '$pi__raw' (expected forms: 90, 15m, 2h)"
    unset pi__raw pi__num pi__unit
    return 1
  fi

  pi__minutes=""
  case "$pi__unit" in
    '' | m | min | mins | minute | minutes )
      pi__minutes="$pi__num"
      ;;
    h | hr | hrs | hour | hours )
      pi__minutes=$(( pi__num * 60 ))
      ;;
    s | sec | secs | second | seconds )
      cc_err "sub-minute intervals are not supported (got '$pi__raw')"
      unset pi__raw pi__num pi__unit pi__minutes
      return 1
      ;;
    * )
      cc_err "unknown interval unit in '$pi__raw' (use m or h)"
      unset pi__raw pi__num pi__unit pi__minutes
      return 1
      ;;
  esac

  if [ "$pi__minutes" -lt 1 ] 2>/dev/null; then
    cc_err "interval must be at least 1 minute (got '$pi__raw')"
    unset pi__raw pi__num pi__unit pi__minutes
    return 1
  fi

  printf '%s\n' "$pi__minutes"
  unset pi__raw pi__num pi__unit pi__minutes
  return 0
}

# ---------------------------------------------------------------------------
# loop_get <id> - print the registry entry for <id> as JSON, or non-zero.
# ---------------------------------------------------------------------------
loop_get() {
  lg__id="$1"
  lg__out="$(registry_read | cc_jq -e --arg id "$lg__id" '.loops[] | select(.id == $id)' 2>/dev/null)"
  lg__rc=$?
  if [ "$lg__rc" -ne 0 ] || [ -z "$lg__out" ]; then
    unset lg__id lg__out lg__rc
    return 1
  fi
  printf '%s\n' "$lg__out"
  unset lg__id lg__out lg__rc
  return 0
}

# loop_exists <id> - return 0 if a loop with <id> is present.
loop_exists() {
  registry_read | cc_jq -e --arg id "$1" 'any(.loops[]; .id == $id)' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# loop_upsert - insert or replace a loop entry. Fields via flags; sensible
# defaults injected for anything omitted on insert.
#
# Usage:
#   loop_upsert --id <slug> [--enabled true|false] [--interval <spec>]
#               [--cwd <abs>] [--add-dir <abs>]... [--allowed-tools <csv>]
#               [--prompt-file <rel>] [--backend claude|codex]
# ---------------------------------------------------------------------------
loop_upsert() {
  lu__id=""
  lu__enabled=""
  lu__interval=""
  lu__cwd=""
  lu__allowed=""
  lu__prompt=""
  lu__backend=""
  lu__has_adddirs=0
  # Build add_dirs JSON array incrementally.
  lu__adddirs_json='[]'

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id )            lu__id="$2"; shift 2 ;;
      --enabled )       lu__enabled="$2"; shift 2 ;;
      --interval )      lu__interval="$2"; shift 2 ;;
      --cwd )           lu__cwd="$2"; shift 2 ;;
      --allowed-tools ) lu__allowed="$2"; shift 2 ;;
      --prompt-file )   lu__prompt="$2"; shift 2 ;;
      --backend )       lu__backend="$2"; shift 2 ;;
      --add-dir )
        lu__has_adddirs=1
        lu__adddirs_json="$(printf '%s' "$lu__adddirs_json" | cc_jq --arg d "$2" '. + [$d]')"
        shift 2
        ;;
      * )
        cc_err "loop_upsert: unknown argument '$1'"
        return 1
        ;;
    esac
  done

  validate_id "$lu__id" || return 1
  registry_ensure || return 1

  # Resolve interval if provided.
  lu__interval_min=""
  if [ -n "$lu__interval" ]; then
    lu__interval_min="$(parse_interval "$lu__interval")" || return 1
  fi

  # Existing entry (for merge) or empty object.
  lu__existing="$(loop_get "$lu__id" 2>/dev/null || printf '')"

  # Default prompt file if not set and not pre-existing.
  if [ -z "$lu__prompt" ] && [ -z "$lu__existing" ]; then
    lu__prompt="prompts/$lu__id.md"
  fi

  # Build the patch object: only include explicitly provided fields, plus
  # defaults for a brand-new entry.
  lu__patch="$(cc_jq -n \
    --arg id "$lu__id" \
    --arg enabled "$lu__enabled" \
    --arg interval "$lu__interval_min" \
    --arg cwd "$lu__cwd" \
    --argjson adddirs "$lu__adddirs_json" \
    --arg has_adddirs "$lu__has_adddirs" \
    --arg allowed "$lu__allowed" \
    --arg prompt "$lu__prompt" \
    --arg backend "$lu__backend" \
    '
      { id: $id }
      + ( if $enabled  != "" then { enabled: ($enabled == "true") } else {} end )
      + ( if $interval != "" then { interval_minutes: ($interval | tonumber) } else {} end )
      + ( if $cwd      != "" then { cwd: $cwd } else {} end )
      + ( if $has_adddirs == "1" then { add_dirs: $adddirs } else {} end )
      + ( if $allowed  != "" then { allowed_tools: $allowed } else {} end )
      + ( if $prompt   != "" then { prompt_file: $prompt } else {} end )
      + ( if $backend  != "" then { backend: $backend } else {} end )
    ')"

  # Defaults applied only for fields absent in BOTH existing and patch.
  lu__defaults="$(cc_jq -n \
    --argjson interval "$CLAUDECRON_DEFAULT_INTERVAL_MINUTES" \
    --arg allowed "$CLAUDECRON_DEFAULT_ALLOWED_TOOLS" \
    --arg backend "$CLAUDECRON_DEFAULT_BACKEND" \
    --arg id "$lu__id" \
    '{ id: $id, enabled: true, interval_minutes: $interval, cwd: ".",
       add_dirs: [], allowed_tools: $allowed, prompt_file: ("prompts/" + $id + ".md"),
       backend: $backend }')"

  if [ -n "$lu__existing" ]; then
    # Merge: existing wins over defaults, patch wins over existing.
    lu__merged="$(printf '%s' "$lu__defaults" \
      | cc_jq -s '.[0] * .[1] * .[2]' - <(printf '%s' "$lu__existing") <(printf '%s' "$lu__patch") 2>/dev/null)"
    if [ -z "$lu__merged" ]; then
      # Fallback without process substitution for shells/environments
      # where /dev/fd is unavailable: chain via jq --slurpfile.
      lu__merged="$(printf '%s' "$lu__existing" | cc_jq \
        --argjson defs "$lu__defaults" --argjson patch "$lu__patch" \
        '$defs * . * $patch')"
    fi
  else
    lu__merged="$(printf '%s' "$lu__defaults" | cc_jq --argjson patch "$lu__patch" '. * $patch')"
  fi

  # Replace-or-append into registry .loops, then atomic write.
  registry_read | cc_jq --arg id "$lu__id" --argjson entry "$lu__merged" '
      .loops = ( ( .loops | map(select(.id != $id)) ) + [ $entry ] )
    ' | cc__atomic_write_stdin "$CLAUDECRON_REGISTRY" || return 1

  cc_log "upserted loop '$lu__id'"
  unset lu__id lu__enabled lu__interval lu__cwd lu__allowed lu__prompt lu__backend
  unset lu__has_adddirs lu__adddirs_json lu__interval_min lu__existing lu__patch
  unset lu__defaults lu__merged
  return 0
}

# ---------------------------------------------------------------------------
# loop_remove <id> - delete a loop entry. Returns non-zero if it was absent.
# ---------------------------------------------------------------------------
loop_remove() {
  lr__id="$1"
  validate_id "$lr__id" || return 1
  if ! loop_exists "$lr__id"; then
    cc_err "loop '$lr__id' not found in registry"
    unset lr__id
    return 1
  fi
  registry_ensure || return 1
  registry_read | cc_jq --arg id "$lr__id" '.loops = (.loops | map(select(.id != $id)))' \
    | cc__atomic_write_stdin "$CLAUDECRON_REGISTRY" || return 1
  cc_log "removed loop '$lr__id'"
  unset lr__id
  return 0
}
