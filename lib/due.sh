#!/usr/bin/env bash
# Copyright (c) 2026 The claudecron authors
#
# lib/due.sh - time helpers and due-ness computation.
#
# Detects BSD date (date -j) vs GNU date (date -d) ONCE and caches the flavor.
# No GNU-only constructs are assumed.
#
# Depends on lib/common.sh only for logging (optional).

if [ -n "${CLAUDECRON_DUE_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
CLAUDECRON_DUE_SOURCED=1

# epoch_now - current time in epoch seconds.
epoch_now() {
  date '+%s'
}

# ---------------------------------------------------------------------------
# Date flavor detection (run once on first use, cached in CLAUDECRON_DATE_FLAVOR).
# Values: "bsd" (date -j), "gnu" (date -d), or "none".
# ---------------------------------------------------------------------------
due__detect_date_flavor() {
  if [ -n "${CLAUDECRON_DATE_FLAVOR:-}" ]; then
    return 0
  fi
  # GNU date understands -d; BSD date understands -j -f.
  if date -j -f '%Y-%m-%dT%H:%M:%S' '1970-01-01T00:00:00' '+%s' >/dev/null 2>&1; then
    CLAUDECRON_DATE_FLAVOR="bsd"
  elif date -d '1970-01-01T00:00:00' '+%s' >/dev/null 2>&1; then
    CLAUDECRON_DATE_FLAVOR="gnu"
  else
    CLAUDECRON_DATE_FLAVOR="none"
  fi
  export CLAUDECRON_DATE_FLAVOR
  return 0
}

# ---------------------------------------------------------------------------
# iso_to_epoch <iso8601> - convert an ISO-8601 timestamp to epoch seconds.
# Accepts a trailing Z or numeric offset; the offset is treated as local on
# BSD's naive parse path, which is acceptable here because we only ever feed
# back timestamps we ourselves produced. If the input is already a bare epoch
# (all digits) it is echoed through unchanged.
# ---------------------------------------------------------------------------
iso_to_epoch() {
  ite__in="$1"

  # Bare epoch passthrough.
  case "$ite__in" in
    '' )
      return 1
      ;;
    *[!0-9]* )
      : # has non-digits -> parse as ISO below
      ;;
    * )
      printf '%s\n' "$ite__in"
      unset ite__in
      return 0
      ;;
  esac

  due__detect_date_flavor

  # Normalize: drop a trailing Z, and strip a numeric tz offset (+0000/-05:00)
  # so the naive parsers accept it.
  ite__norm="$ite__in"
  ite__norm="$(printf '%s' "$ite__norm" | sed 's/Z$//; s/[+-][0-9][0-9]:\{0,1\}[0-9][0-9]$//')"

  ite__epoch=""
  case "$CLAUDECRON_DATE_FLAVOR" in
    bsd )
      ite__epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S' "$ite__norm" '+%s' 2>/dev/null)"
      if [ -z "$ite__epoch" ]; then
        # Try a space-separated variant.
        ite__epoch="$(date -j -f '%Y-%m-%d %H:%M:%S' "$ite__norm" '+%s' 2>/dev/null)"
      fi
      ;;
    gnu )
      ite__epoch="$(date -d "$ite__in" '+%s' 2>/dev/null)"
      ;;
    * )
      unset ite__in ite__norm ite__epoch
      return 1
      ;;
  esac

  if [ -z "$ite__epoch" ]; then
    unset ite__in ite__norm ite__epoch
    return 1
  fi

  printf '%s\n' "$ite__epoch"
  unset ite__in ite__norm ite__epoch
  return 0
}

# ---------------------------------------------------------------------------
# is_due <last_run_epoch> <interval_minutes>
#   Returns 0 (due) when:
#     - last_run_epoch is empty/missing (never ran), OR
#     - now - last_run >= interval_minutes * 60.
#   Returns 1 (not due) otherwise, INCLUDING when the delta is negative
#   (clock moved backwards) - we conservatively treat that as not due.
# ---------------------------------------------------------------------------
is_due() {
  id__last="$1"
  id__interval_min="$2"

  # Never ran -> due.
  case "$id__last" in
    ''|null )
      unset id__last id__interval_min
      return 0
      ;;
  esac

  # If last is non-numeric (e.g. an ISO string), try to convert.
  case "$id__last" in
    *[!0-9]* )
      id__last="$(iso_to_epoch "$id__last" 2>/dev/null)"
      if [ -z "$id__last" ]; then
        # Unparseable -> treat as never ran (due).
        unset id__last id__interval_min
        return 0
      fi
      ;;
  esac

  # Validate interval.
  case "$id__interval_min" in
    ''|*[!0-9]* )
      id__interval_min=0
      ;;
  esac

  id__now="$(epoch_now)"
  id__delta=$(( id__now - id__last ))

  # Clock went backwards -> not due (avoid a false trigger storm).
  if [ "$id__delta" -lt 0 ]; then
    unset id__last id__interval_min id__now id__delta
    return 1
  fi

  id__threshold=$(( id__interval_min * 60 ))
  if [ "$id__delta" -ge "$id__threshold" ]; then
    unset id__last id__interval_min id__now id__delta id__threshold
    return 0
  fi

  unset id__last id__interval_min id__now id__delta id__threshold
  return 1
}
