#!/usr/bin/env bash
# Build a bench tree that provably reviews the SAME BYTES the hosted reviewer
# saw, and refuse to produce one that does not.
#
#   ./prepare-bench-tree.sh <patchset-id> [<tree-name>]
#
# On success it prints a REVIEW_RANGE line; on failure it exits non-zero and
# prints why. Nothing downstream should score a tree this script rejected.
#
# WHY VERIFICATION, NOT CARE
# --------------------------
# "mptcp: do not drop partial packets" is committed EIGHT times in the clone
# (2026-04-22 .. 2026-05-30). Picking "the commit with that subject" picked the
# wrong revision, and we scored a review against findings written about
# different code. Subject matching, date matching and "looks right" all failed.
# Blob hashes did not.
#
# The hosted review records everything needed:
#   review.baseline.commit           tree state the patch was applied to
#   review.inline_review  ->  the quoted diff's `index <pre>..<post>` line,
#                             which is the git blob hash of the touched file
#                             before and after. That is the ground truth.
#
# METHOD
#   1. read baseline + blob hashes + message-id from the corpus JSON
#   2. locate a commit whose file blob == hosted's PRE-image. The recorded
#      baseline is often gone (mptcp export branches are rebased and the old
#      commits get garbage collected upstream), but the CONTENT usually still
#      exists somewhere in the clone -- and content is what a review reads.
#   3. fetch the posted patch with b4 (lore's /raw is behind an anti-bot
#      challenge for scripts; b4 uses t.mbox.gz and works)
#   4. detached worktree, apply, and VERIFY the post-image blob
set -uo pipefail
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/config.sh"

PSID="${1:?usage: prepare-bench-tree.sh <patchset-id> [tree-name]}"
NAME="${2:-bench_${PSID}}"
S=$SAMIKSHAKA_ROOT
K=$KERNEL_TREE
CORPUS="$S/corpus/data/sashiko-hosted/mptcp/reviews/${PSID}.json"
TREE="$S/bench_trees/${NAME}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[ -f "$CORPUS" ] || { echo "no corpus entry: $CORPUS" >&2; exit 2; }
command -v b4 >/dev/null || { echo "b4 not installed (pip install b4)" >&2; exit 2; }

read -r BASE PRE POST MID FILE <<<"$(python3 - "$CORPUS" <<'PY'
import json,sys,re
d=json.load(open(sys.argv[1])); ps=d.get("patchset") or {}
base=pre=post=mid=path=""
for r in ps.get("reviews") or []:
    if not isinstance(r,dict): continue
    base = base or ((r.get("baseline") or {}).get("commit") or "")
    inl = r.get("inline_review") or ""
    m = re.search(r"^>?\s*index ([0-9a-f]{7,})\.\.([0-9a-f]{7,})", inl, re.M)
    if m and not pre: pre,post = m.group(1),m.group(2)
    f = re.search(r"^>?\s*\+\+\+ b/(\S+)", inl, re.M)
    if f and not path: path = f.group(1)
mid=((ps.get("patches") or [{}])[0]).get("message_id") or ""
print(base or "-", pre or "-", post or "-", mid or "-", path or "-")
PY
)"

echo "patchset  : $PSID"
echo "baseline  : $BASE"
echo "file      : $FILE"
echo "blobs     : ${PRE}..${POST}"
echo "message-id: $MID"
echo

[ "$PRE" = "-" ] || [ "$POST" = "-" ] || [ "$FILE" = "-" ] && {
  echo "REJECT: corpus entry has no quoted diff, so reproduction cannot be verified." >&2; exit 3; }
[ "$MID" = "-" ] && { echo "REJECT: no message-id; cannot fetch the posted patch." >&2; exit 3; }

# --- 2. find a commit carrying hosted's pre-image content ------------------
ANCHOR=""
if git -C "$K" cat-file -e "${BASE}^{commit}" 2>/dev/null &&
   [ "$(git -C "$K" rev-parse --short=${#PRE} "${BASE}:${FILE}" 2>/dev/null)" = "$PRE" ]; then
  ANCHOR="$BASE"
  echo "anchor    : recorded baseline $BASE (pre-image matches)"
else
  echo "recorded baseline unusable; searching the clone for blob $PRE ..."
  while read -r C; do
    [ "$(git -C "$K" rev-parse --short=${#PRE} "${C}:${FILE}" 2>/dev/null)" = "$PRE" ] && { ANCHOR="$C"; break; }
  done < <(git -C "$K" log --all --format='%H' -- "$FILE" 2>/dev/null | head -800)
  [ -n "$ANCHOR" ] || { echo "REJECT: no commit in the clone has ${FILE} == ${PRE}." >&2
                        echo "        try: git -C $K fetch mptcp '+refs/heads/*:refs/remotes/mptcp/*'" >&2; exit 4; }
  echo "anchor    : $(git -C "$K" rev-parse --short "$ANCHOR") (content match, not the recorded baseline)"
fi

# --- 3. fetch the posted patch --------------------------------------------
# `b4 mbox` returns the whole THREAD (cover letter, replies, review mail) and
# git am chokes on it. `b4 am` emits a ready-to-apply series, picking the
# newest revision and dropping non-patch mail.
# b4 am defaults to the NEWEST revision of a series. Hosted often reviewed an
# earlier posting (v1 of a thread that later reached v3), which shows up as a
# post-image mismatch. Try the default first, then walk v1..v4, and keep
# whichever reproduces hosted's post-image. Two of five candidates were
# recovered this way.
try_fetch() {   # $1 = "" or a version number
  rm -f "$WORK"/*.mbx 2>/dev/null
  if [ -z "$1" ]; then b4 am -o "$WORK" -n patch --no-cover "$MID" >/dev/null 2>&1
  else                 b4 am -o "$WORK" -n patch --no-cover -v "$1" "$MID" >/dev/null 2>&1; fi
  ls "$WORK"/*.mbx 2>/dev/null | head -1
}

# --- 4. worktree, apply, verify -------------------------------------------
[ -d "$TREE" ] && { git -C "$K" worktree remove --force "$TREE" 2>/dev/null; rm -rf "$TREE"; }
git -C "$K" worktree add --detach "$TREE" "$ANCHOR" >/dev/null 2>&1 \
  || { echo "REJECT: worktree add failed" >&2; exit 6; }

MATCHED=""
LAST=""
for V in "" 1 2 3 4; do
  MBX=$(try_fetch "$V")
  [ -n "$MBX" ] || continue
  git -C "$TREE" am --abort 2>/dev/null
  git -C "$TREE" reset -q --hard "$ANCHOR"; git -C "$TREE" clean -qfdx
  git -C "$TREE" -c user.name=bench -c user.email=bench@local am -3 "$MBX" >/dev/null 2>&1 || continue
  ACT=$(git -C "$TREE" rev-parse --short=${#POST} "HEAD:${FILE}" 2>/dev/null)
  LAST="$ACT"
  if [ "$ACT" = "$POST" ]; then
    MATCHED="${V:-default}"; break
  fi
done
if [ -z "$MATCHED" ]; then
  git -C "$TREE" am --abort 2>/dev/null
  echo "REJECT: no revision reproduced hosted's post-image (last tried gave ${LAST:-none}, wanted ${POST})." >&2
  echo "        This tree is NOT the review target; do not score it." >&2
  exit 8
fi
echo "revision  : ${MATCHED}"

echo
echo "VERIFIED: pre-image and post-image both match the hosted review."
echo "TREE=${TREE}"
echo "REVIEW_RANGE=$(git -C "$TREE" rev-parse --short HEAD)^..$(git -C "$TREE" rev-parse --short HEAD)"
