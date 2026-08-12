#!/usr/bin/env bash
# Turn "something the user said" into a reviewable tree + range.
#
#   setup-review-target.sh HEAD
#   setup-review-target.sh <sha> | <range>
#   setup-review-target.sh 20260422120954.8877-1-someone@example.com
#   setup-review-target.sh https://lore.kernel.org/mptcp/<msgid>/
#   setup-review-target.sh --patchset 12427          # a hosted Sashiko id
#   setup-review-target.sh --file /path/to/patch.mbx
#
# Prints, on success:
#   TREE=<path>
#   RANGE=<rev>^..<rev>
#   VERIFIED=<yes|content-only|no>
# and exits 0. On failure prints why and exits non-zero. Nothing downstream
# should review a target this script did not print a RANGE for.
#
# WHY IT EXISTS
# One patch subject in the MPTCP corpus is committed EIGHT times across a month.
# Picking "the commit with that subject" picked the wrong revision and produced
# a review of code the author never posted. Resolution has to be explicit.
set -uo pipefail

# Resolve the repo from this script's own location, then load site paths.
# Resolve through symlinks: the skill is normally installed as a symlink from
# ~/.claude/skills, and dirname on the link path walks the link, not the repo.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REVIEW_REPO="$(cd "$(dirname "$SELF")/../.." && pwd)"
. "$REVIEW_REPO/config.sh"
KERNEL="$KERNEL_TREE"
WORKROOT="$REVIEW_WORKROOT"

die() { echo "SETUP FAILED: $*" >&2; exit 1; }

MODE=""; ARG=""
case "${1:-}" in
  "")            die "nothing to review. Pass HEAD, a sha, a range, a message-id, a lore URL, --patchset <id> or --file <mbox>" ;;
  --patchset)    MODE=patchset; ARG="${2:?--patchset needs an id}" ;;
  --file)        MODE=file;     ARG="${2:?--file needs a path}" ;;
  http*)         MODE=msgid;    ARG=$(echo "$1" | sed -E 's|.*/([^/]+@[^/]+)/?.*|\1|') ;;
  *@*)           MODE=msgid;    ARG="$1" ;;
  *)             MODE=gitref;   ARG="$1" ;;
esac

# ---------------------------------------------------------------- git ref ---
if [ "$MODE" = gitref ]; then
  T="${REVIEW_TREE:-$KERNEL}"
  git -C "$T" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $T"
  if [[ "$ARG" == *".."* ]]; then
    git -C "$T" rev-parse "${ARG%%..*}" >/dev/null 2>&1 || die "cannot resolve range: $ARG"
    RANGE="$ARG"
  else
    SHA=$(git -C "$T" rev-parse --short "$ARG" 2>/dev/null) || die "cannot resolve: $ARG"
    RANGE="${SHA}^..${SHA}"
  fi
  # A dirty tree means the reviewer may read code the patch does not contain.
  if [ -n "$(git -C "$T" status --porcelain --untracked-files=no)" ]; then
    echo "WARNING: $T has uncommitted tracked changes; the review may see them" >&2
  fi
  echo "TREE=$T"; echo "RANGE=$RANGE"; echo "VERIFIED=no (reviewing the tree as-is, nothing to verify against)"
  exit 0
fi

# ------------------------------------------------------------- patchset id ---
if [ "$MODE" = patchset ]; then
  exec "$REVIEW_REPO/harness/prepare-bench-tree.sh" "$ARG" "review_${ARG}"
fi

# --------------------------------------------------- message-id / mbox file ---
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
if [ "$MODE" = msgid ]; then
  command -v b4 >/dev/null || die "b4 not installed (pip install b4). lore's /raw endpoint is behind an anti-bot challenge, so curl is not an alternative."
  echo "fetching $ARG with b4 ..." >&2
  b4 am -o "$WORK" -n patch --no-cover "$ARG" >/dev/null 2>&1
  MBX=$(ls "$WORK"/*.mbx 2>/dev/null | head -1)
  [ -n "$MBX" ] || die "b4 could not produce a series for $ARG"
else
  MBX="$ARG"; [ -f "$MBX" ] || die "no such file: $MBX"
fi

# Base selection, in order of trustworthiness:
#   1. a base-commit: trailer in the patch itself
#   2. REVIEW_BASE from the environment
#   3. the tip of the kernel tree's current branch, reported loudly
BASE=$(grep -m1 -oP '^base-commit:\s*\K[0-9a-f]{12,40}' "$MBX" || true)
SRC="base-commit: trailer"
if [ -z "$BASE" ]; then BASE="${REVIEW_BASE:-}"; SRC="REVIEW_BASE"; fi
if [ -z "$BASE" ]; then
  # No trailer and no override. Guess from the patch's own date: the author
  # based it on something that existed then, so walk the tracked branches back
  # to that point. Trying HEAD is nearly always wrong for anything but a patch
  # posted today.
  PDATE=$(grep -m1 -oP '^Date:\s*\K.*' "$MBX" || true)
  if [ -n "$PDATE" ]; then
    for REF in mptcp/export mptcp/master remotes/mptcp/export remotes/mptcp/master origin/master master; do
      git -C "$KERNEL" rev-parse --verify "$REF" >/dev/null 2>&1 || continue
      C=$(git -C "$KERNEL" rev-list -1 --before="$PDATE" "$REF" 2>/dev/null) || continue
      [ -n "$C" ] && { BASE="$C"; SRC="newest commit on $REF before the patch date ($PDATE)"; break; }
    done
  fi
fi
if [ -z "$BASE" ]; then BASE=$(git -C "$KERNEL" rev-parse HEAD); SRC="kernel tree HEAD (NOT the author's base)"; fi
git -C "$KERNEL" cat-file -e "${BASE}^{commit}" 2>/dev/null || {
  echo "base $BASE not present; fetching..." >&2
  git -C "$KERNEL" fetch mptcp '+refs/heads/*:refs/remotes/mptcp/*' >/dev/null 2>&1
  git -C "$KERNEL" cat-file -e "${BASE}^{commit}" 2>/dev/null || die "base commit $BASE unavailable even after fetch"
}

# Name the worktree after the message-id, not after b4's generic output file:
# every fetched series is called "patch.mbx", so basename would collide two
# different patches onto one directory.
if [ "$MODE" = msgid ]; then
  NAME="review_$(echo "$ARG" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-48)"
else
  NAME="review_$(basename "$MBX" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-48)"
fi
TREE="$WORKROOT/$NAME"
mkdir -p "$WORKROOT"
[ -d "$TREE" ] && { git -C "$KERNEL" worktree remove --force "$TREE" 2>/dev/null; rm -rf "$TREE"; }
git -C "$KERNEL" worktree add --detach "$TREE" "$BASE" >/dev/null 2>&1 || die "worktree add failed at $BASE"

apply_at() {   # $1 = base sha; returns 0 if the series applies there
  git -C "$TREE" am --abort >/dev/null 2>&1
  git -C "$TREE" checkout -q --detach "$1" 2>/dev/null || return 1
  git -C "$TREE" reset -q --hard "$1"; git -C "$TREE" clean -qfdx
  git -C "$TREE" -c user.name=review -c user.email=review@local am -3 "$MBX" >/dev/null 2>&1
}

if ! apply_at "$BASE"; then
  echo "does not apply at $BASE; trying nearby commits on the tracked branches..." >&2
  FOUND=""
  PDATE=$(grep -m1 -oP '^Date:\s*\K.*' "$MBX" || true)
  for REF in mptcp/export mptcp/master origin/master; do
    git -C "$KERNEL" rev-parse --verify "$REF" >/dev/null 2>&1 || continue
    START=$(git -C "$KERNEL" rev-list -1 ${PDATE:+--before="$PDATE"} "$REF" 2>/dev/null) || continue
    [ -n "$START" ] || continue
    for C in $(git -C "$KERNEL" rev-list --max-count=25 "$START"); do
      if apply_at "$C"; then FOUND="$C"; SRC="found by search on $REF"; break 2; fi
    done
  done
  [ -n "$FOUND" ] || die "the patch does not apply at $BASE (source: $SRC) nor at the 25 commits before the patch date on any tracked branch. Supply the base explicitly with REVIEW_BASE=<sha>."
  BASE="$FOUND"
fi

N=$(git -C "$TREE" rev-list --count "${BASE}..HEAD")
[ "$N" -ge 1 ] || die "nothing applied"
FIRST=$(git -C "$TREE" rev-parse --short "${BASE}")
echo "TREE=$TREE"
echo "RANGE=${FIRST}..$(git -C "$TREE" rev-parse --short HEAD)"
echo "PATCHES=$N"
echo "BASE_SOURCE=$SRC"
echo "VERIFIED=content-only (applied cleanly; no published review to compare blob hashes against)"
