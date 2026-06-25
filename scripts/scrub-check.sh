#!/usr/bin/env bash
# scrub-check.sh - privacy/leak gate for the claudecron repo.
#
# Scans the whole tree for identifiers that must NEVER appear in this public
# project: personal names/emails, the originating company/org, internal product
# and infra names, real home-directory paths, chat-platform IDs, and secret-token
# shapes. Exits non-zero (and prints every hit) if anything matches, so it can
# gate a pre-push hook and CI. Generic English words that merely overlap with a
# forbidden term (e.g. "aware" inside "awareness") are avoided by anchoring the
# risky patterns to word boundaries where it matters.
#
# Usage: scripts/scrub-check.sh [ROOT]   (ROOT defaults to repo root)
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# This script necessarily contains the forbidden literals (they are its
# blocklist), so it must exclude itself from the scan - otherwise the gate can
# never pass. Exactly one file is excluded, by name, so the exclusion cannot be
# abused to hide leaks elsewhere.
SELF_NAME="scrub-check.sh"

# Allowlist: the project is hosted at github.com/awreai/claudecron, so the org
# handle legitimately appears in install URLs, the Homebrew formula, and the
# release workflow. We strip ONLY the exact repo-path token "awreai/claudecron"
# (and the homebrew tap "awreai/homebrew-tap") from each line before evaluating,
# so a bare "awreai" or "awre" anywhere else still trips the gate. This is a
# token-level allow, not a file or pattern exemption.
ALLOW_RE='awreai/(claudecron|homebrew-tap|tap)'

# Prefer ripgrep (fast, pcre2); fall back to grep -E. After matching, blank out
# the allowlisted token so a line that contained ONLY the allowed URL no longer
# counts as a hit for the org/company patterns.
if command -v rg >/dev/null 2>&1; then
  SCAN() { rg --pcre2 -n -i --no-heading \
            -g '!.git' -g '!*.lock' -g '!*.min.*' -g '!dist' -g "!$SELF_NAME" \
            -e "$1" "$ROOT" 2>/dev/null \
            | perl -pe "s{$ALLOW_RE}{REPO_URL}gi" \
            | grep -iE "$1" 2>/dev/null; }
else
  SCAN() { grep -rInE -i \
            --exclude-dir=.git --exclude='*.lock' --exclude='*.min.*' --exclude-dir=dist \
            --exclude="$SELF_NAME" \
            "$1" "$ROOT" 2>/dev/null \
            | sed -E "s#$ALLOW_RE#REPO_URL#gi" \
            | grep -iE "$1" 2>/dev/null; }
fi

# Each entry: "label::regex". Regexes are case-insensitive (SCAN passes -i).
# Word-boundary anchors keep generic words from false-positiving while still
# catching the real identifiers.
PATTERNS=(
  "person-name::\\bdeepak\\b"
  "person-handle::\\bdgawre\\b"
  "person-email::dg@awre\\.ai"
  "person-email2::deepak\\.dpkgpt"
  "person-short::(^|[^a-z0-9])dg-(brain|awre|prs)"
  "company::\\bawre\\b"
  "company-org::\\bawreai\\b"
  "company-aware::\\baware\\b"
  "company-domain::@awre\\.ai"
  "slack-workspace::awre-adu5605"
  "slack-channel-id::\\bC0[A-Z0-9]{8,}\\b"
  "slack-user-id::\\bU0[A-Z0-9]{8,}\\b"
  "slack-dm-id::\\bD0[A-Z0-9]{8,}\\b"
  "home-path::/Users/dg(/|\\b)"
  "home-path2::/home/dg(/|\\b)"
  "internal-brain::\\bdg-brain\\b"
  "internal-workspace::workspace/awreai"
  "launchd-label::com\\.awre\\."
  "internal-runner::awre-loops-run"
  "internal-arch::\\b(sprite|composio|clerk|firecracker)\\b"
  "internal-repo::\\b(wire-schema)\\b"
  "secret-slack::xox[baprs]-"
  "secret-gh::gh[pousr]_[A-Za-z0-9]{20,}"
  "secret-anthropic::sk-ant-[A-Za-z0-9-]{10,}"
  "secret-openai::sk-[A-Za-z0-9]{20,}"
  "secret-qstash::qstash_[A-Za-z0-9]{10,}"
)

fail=0
echo "scrub-check: scanning $ROOT"
for entry in "${PATTERNS[@]}"; do
  label="${entry%%::*}"
  regex="${entry#*::}"
  hits="$(SCAN "$regex")"
  if [ -n "$hits" ]; then
    echo ""
    echo "LEAK [$label]  pattern: $regex"
    echo "$hits" | sed 's/^/    /'
    fail=1
  fi
done

echo ""
if [ "$fail" -ne 0 ]; then
  echo "scrub-check: FAILED - forbidden identifiers found above. Do NOT push."
  exit 1
fi
echo "scrub-check: clean - no forbidden identifiers found."
exit 0
