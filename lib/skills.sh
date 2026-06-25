#!/usr/bin/env bash
# Copyright (c) 2026 The claudecron authors
#
# lib/skills.sh - install/remove the agent skills into Claude Code and Codex so
# users can create and manage loops by talking to their agent.
#
# Claude Code discovers skills under ~/.claude/skills/<name>/SKILL.md.
# Codex discovers slash-prompts under ~/.codex/prompts/<name>.md.
#
# All operations are idempotent and best-effort: if an agent is not installed,
# its step is skipped with a note, never an error. Nothing here requires sudo.
#
# Portability: macOS /bin/bash 3.2 safe.

if [ -n "${CLAUDECRON_SKILLS_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDECRON_SKILLS_SOURCED=1

# Where the shipped skill sources live (under the installed libexec tree).
skills__src_dir() {
  printf '%s/skills\n' "${CLAUDECRON_LIBEXEC:-.}"
}

# Resolve agent skill roots, honoring overrides for testing.
skills__claude_dir() {
  printf '%s\n' "${CLAUDECRON_CLAUDE_SKILLS_DIR:-${HOME}/.claude/skills}"
}
skills__codex_prompts_dir() {
  printf '%s\n' "${CLAUDECRON_CODEX_PROMPTS_DIR:-${HOME}/.codex/prompts}"
}

# skills_install - copy the claudecron skills into whichever agents are present.
skills_install() {
  si__src="$(skills__src_dir)"
  si__any=0

  if [ ! -d "$si__src" ]; then
    cc_err "skills source not found at $si__src (is claudecron installed?)"
    return 1
  fi

  # --- Claude Code -------------------------------------------------------
  si__claude="$(skills__claude_dir)"
  # Claude Code is considered present if ~/.claude exists.
  if [ -d "${HOME}/.claude" ]; then
    mkdir -p "$si__claude" 2>/dev/null || true
    if [ -d "$si__src/claudecron" ]; then
      rm -rf "$si__claude/claudecron" 2>/dev/null || true
      cp -R "$si__src/claudecron" "$si__claude/claudecron" 2>/dev/null \
        && cc_log "installed Claude Code skill -> $si__claude/claudecron" \
        || cc_err "failed to install Claude Code skill"
      si__any=1
    fi
    # The lightweight status skill (a quick /claudecron-status command).
    if [ -d "$si__src/claudecron-status" ]; then
      rm -rf "$si__claude/claudecron-status" 2>/dev/null || true
      cp -R "$si__src/claudecron-status" "$si__claude/claudecron-status" 2>/dev/null \
        && cc_log "installed Claude Code skill -> $si__claude/claudecron-status" || true
    fi
  else
    cc_log "Claude Code not detected (~/.claude absent); skipping its skill"
  fi

  # --- Codex -------------------------------------------------------------
  si__codex="$(skills__codex_prompts_dir)"
  if [ -d "${HOME}/.codex" ]; then
    mkdir -p "$si__codex" 2>/dev/null || true
    if [ -f "$si__src/codex-claudecron/AGENTS.md" ]; then
      cp "$si__src/codex-claudecron/AGENTS.md" "$si__codex/claudecron.md" 2>/dev/null \
        && cc_log "installed Codex prompt -> $si__codex/claudecron.md" \
        || cc_err "failed to install Codex prompt"
      si__any=1
    fi
  else
    cc_log "Codex not detected (~/.codex absent); skipping its prompt"
  fi

  if [ "$si__any" -eq 0 ]; then
    cc_log "no supported agent detected; skills not installed (the CLI works standalone)"
  fi
  unset si__src si__any si__claude si__codex
  return 0
}

# skills_remove - remove the installed skills from both agents (best-effort).
skills_remove() {
  sr__claude="$(skills__claude_dir)"
  sr__codex="$(skills__codex_prompts_dir)"
  rm -rf "$sr__claude/claudecron" "$sr__claude/claudecron-status" 2>/dev/null || true
  rm -f "$sr__codex/claudecron.md" 2>/dev/null || true
  cc_log "removed claudecron skills from Claude Code and Codex (where present)"
  unset sr__claude sr__codex
  return 0
}

# skills_status - report where skills are installed.
skills_status() {
  ss__claude="$(skills__claude_dir)"
  ss__codex="$(skills__codex_prompts_dir)"
  if [ -d "$ss__claude/claudecron" ]; then
    printf 'claude code: installed (%s)\n' "$ss__claude/claudecron"
  else
    printf 'claude code: not installed\n'
  fi
  if [ -f "$ss__codex/claudecron.md" ]; then
    printf 'codex: installed (%s)\n' "$ss__codex/claudecron.md"
  else
    printf 'codex: not installed\n'
  fi
  unset ss__claude ss__codex
  return 0
}
