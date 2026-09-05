#!/usr/bin/env bash
# Fire a Sashiko review into the TAIL of a Claude Max usage window.
#
#   ./schedule-review.sh --anchor "2026-08-10 22:15" [--lead 45] [--cycle 5]
#   ./schedule-review.sh                      # uses the saved anchor
#   ./schedule-review.sh --now                # skip waiting, run immediately
#   ./schedule-review.sh --dry-run            # show the schedule, run nothing
#   ./schedule-review.sh -- <args>            # args after -- go to the launcher
#
# What it fires is $REVIEW_LAUNCH_CMD (default: harness/sashiko-review.sh).
#
# WHY THE TAIL OF A WINDOW, NOT THE START
# ---------------------------------------
# Leftover quota expires at the reset, so spending it in the last ~45 minutes
# costs nothing you would otherwise use. If the run overruns, it spills into a
# fresh full window rather than eating the middle of one you wanted for other
# work. Measured review length: 45m10s for one patch, 10 stages -- so a 45
# minute lead lands the finish close to the reset boundary.
#
# WHAT THIS SCRIPT CANNOT DO
# --------------------------
# It cannot read remaining usage. Claude Code exposes that only through the
# interactive /usage command; there is no file or subcommand carrying it
# (checked: no usage/limit state under ~/.claude; policy-limits.json is org
# policy, not consumption). So the TIME half is automated and the USAGE half
# is yours: check /usage before letting this fire, or accept the risk that a
# window is already drained. The script prints the reminder rather than
# pretending to know.
set -uo pipefail
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/config.sh"

mkdir -p "$REVIEW_STATE"
STATE="$REVIEW_STATE/review-schedule"
LEAD=45          # minutes before reset to launch
CYCLE=5          # hours between resets
ANCHOR=""
NOW=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --anchor) ANCHOR="$2"; shift 2 ;;
    --lead)   LEAD="$2"; shift 2 ;;
    --cycle)  CYCLE="$2"; shift 2 ;;
    --now)    NOW=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --) shift; break ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$ANCHOR" ]; then
  date -d "$ANCHOR" +%s >/dev/null 2>&1 || { echo "cannot parse anchor: $ANCHOR" >&2; exit 2; }
  echo "$ANCHOR" > "$STATE"
  echo "anchor saved: $ANCHOR"
fi
[ -s "$STATE" ] || { echo "no anchor saved. Run once with:" >&2
                     echo "  $0 --anchor \"YYYY-MM-DD HH:MM\"   # a known reset time" >&2; exit 2; }
ANCHOR="$(cat "$STATE")"

A=$(date -d "$ANCHOR" +%s)
N=$(date +%s)
STEP=$(( CYCLE * 3600 ))
# Next reset at or after now, walking forward from the anchor.
K=$(( (N - A) / STEP ))
NEXT=$(( A + (K + 1) * STEP ))
[ "$NEXT" -le "$N" ] && NEXT=$(( NEXT + STEP ))
FIRE=$(( NEXT - LEAD * 60 ))
[ "$FIRE" -le "$N" ] && { NEXT=$(( NEXT + STEP )); FIRE=$(( NEXT - LEAD * 60 )); }

echo "anchor      : $ANCHOR  (cycle ${CYCLE}h)"
echo "next reset  : $(date -d "@$NEXT" '+%F %H:%M')"
echo "launch at   : $(date -d "@$FIRE" '+%F %H:%M')   (${LEAD} min before reset)"
echo "wait        : $(( (FIRE - N) / 60 )) min"
echo
echo "REMINDER: this script cannot see your remaining usage. Check /usage first."
echo "          A review needs roughly a full 45 minutes of headroom."

[ "$DRY" -eq 1 ] && exit 0

if [ "$NOW" -eq 0 ]; then
  SLEEP=$(( FIRE - N ))
  [ "$SLEEP" -gt 0 ] && sleep "$SLEEP"
fi

# --- preconditions -------------------------------------------------------
if pgrep -x sashiko >/dev/null; then
  echo "ABORT: a sashiko review is already running" >&2; exit 3
fi
LEFTOVER=$(pgrep -cf 'claude --print --output-format json --no-session-persistence' 2>/dev/null || echo 0)
if [ "${LEFTOVER:-0}" -gt 0 ]; then
  echo "ABORT: ${LEFTOVER} orphaned review worker(s) still running; they drain quota." >&2
  echo "       clean them first, then retry." >&2
  exit 3
fi

echo
echo "=== launching review at $(date '+%F %H:%M:%S') ==="
exec "$REVIEW_LAUNCH_CMD" "$@"
