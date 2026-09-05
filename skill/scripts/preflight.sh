#!/usr/bin/env bash
# Copyright 2026 Shardul Bankar <shardul.b@mpiricsoftware.com>
# SPDX-License-Identifier: Apache-2.0
#
# Check everything a review needs BEFORE starting one.
#
# The failure this exists to prevent is silent degradation. A missing kernel
# tree is loud -- setup-review-target.sh refuses. A missing prompt bundle is
# not: the review simply proceeds without the corpus it is supposed to defer
# to, and produces a worse result that looks exactly like a good one.
#
#   preflight.sh              # human-readable report
#   preflight.sh --quiet      # print only problems
#
# Exit 0 if everything REQUIRED is present, 1 otherwise. RECOMMENDED and
# CONDITIONAL items never affect the exit code -- they tell you which parts of
# the procedure are unavailable, not that you must stop.
set -uo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REVIEW_REPO="$(cd "$(dirname "$SELF")/../.." && pwd)"
. "$REVIEW_REPO/config.sh"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

MISSING_REQ=0
ok()   { [ "$QUIET" -eq 1 ] || printf '  [ok]      %-26s %s\n' "$1" "${2:-}"; }
warn() { printf '  [absent]  %-26s %s\n' "$1" "${2:-}"; [ -n "${3:-}" ] && printf '            -> %s\n' "$3"; }
bad()  { printf '  [MISSING] %-26s %s\n' "$1" "${2:-}"; [ -n "${3:-}" ] && printf '            -> %s\n' "$3"; MISSING_REQ=$((MISSING_REQ+1)); }
head_() { [ "$QUIET" -eq 1 ] || printf '\n%s\n' "$1"; }

[ "$QUIET" -eq 1 ] || echo "kernel-patch-review preflight"

# ---------------------------------------------------------------- required ---
head_ "REQUIRED -- a review must not start without these"

HAVE_GIT=0
if command -v git >/dev/null 2>&1; then HAVE_GIT=1; ok "git" "$(git --version | awk '{print $3}')"
else bad "git" "not on PATH" "install git"; fi

if [ "$HAVE_GIT" -eq 0 ]; then
    # Without git the tree cannot be probed. Saying "not a git repo" here would
    # send the user to fix the wrong thing.
    bad "kernel tree" "cannot check without git" "install git, then re-run"
elif [ -n "${KERNEL_TREE:-}" ] && git -C "$KERNEL_TREE" rev-parse --git-dir >/dev/null 2>&1; then
    _dirty=$(git -C "$KERNEL_TREE" status --porcelain 2>/dev/null | head -1)
    ok "kernel tree" "$KERNEL_TREE${_dirty:+  (uncommitted changes present)}"
elif [ -n "${KERNEL_TREE:-}" ]; then
    bad "kernel tree" "not a git repo: $KERNEL_TREE" "set KERNEL_TREE in config.local.sh"
else
    bad "kernel tree" "KERNEL_TREE unset" \
        "run from inside your kernel tree, or set KERNEL_TREE in config.local.sh"
fi

# The prompt bundle. SKILL.md defers to this corpus wherever the two overlap;
# without it the procedure runs on its own summaries of rules it does not have.
if [ -n "${SASHIKO_PROMPTS:-}" ] && [ -d "$SASHIKO_PROMPTS" ]; then
    ok "Sashiko prompt bundle" "$SASHIKO_PROMPTS"
    for f in false-positive-guide.md severity.md; do
        if [ -f "$SASHIKO_PROMPTS/$f" ]; then ok "bundle: $f" "$(wc -l <"$SASHIKO_PROMPTS/$f") lines"
        else bad "bundle: $f" "absent from the bundle" "the bundle looks incomplete; reinstall it"; fi
    done
    _sub=$(ls "$SASHIKO_PROMPTS"/subsystem/*.md 2>/dev/null | wc -l)
    if [ "$_sub" -gt 0 ]; then ok "bundle: subsystem/" "$_sub files"
    else bad "bundle: subsystem/" "empty or absent" "the bundle looks incomplete; reinstall it"; fi
else
    bad "Sashiko prompt bundle" "SASHIKO_PROMPTS not found" \
        "git clone https://github.com/sashiko-dev/sashiko.git && echo \"SASHIKO_PROMPTS=\$PWD/sashiko/third_party/prompts/kernel\" >> $REVIEW_REPO/config.local.sh"
fi

# ------------------------------------------------------------- recommended ---
head_ "RECOMMENDED -- named by SKILL.md; the listed step is unavailable without it"
_rec() {
    if [ -n "${SASHIKO_PROMPTS:-}" ] && [ -f "$SASHIKO_PROMPTS/$1" ]; then ok "$1" "$2"
    else warn "$1" "$2" "part of the Sashiko prompt bundle"; fi
}
_rec review-core.md        "the full analysis protocol (section 2e)"
_rec pointer-guards.md     "guard ordering and coupling (section 2e)"
_rec fixes-tag.md          "Fixes: verification (sections 2d, 2e)"
_rec missing-fixes-tag.md  "detecting an absent Fixes: tag"
_rec lore-thread.md        "reading the list thread around a patch"
_rec technical-patterns.md "loaded by the staged pipeline"
_rec callstack.md          "loaded by the staged pipeline"
_rec coccinelle.md         "mechanical cross-tree pattern checks"

# ------------------------------------------------------------- conditional ---
head_ "CONDITIONAL -- needed only for the use named"
if command -v b4 >/dev/null 2>&1; then ok "b4" "$(b4 --version 2>&1 | head -1)"
else warn "b4" "reviewing by message-id or lore URL" "pip install b4"; fi

if command -v python3 >/dev/null 2>&1; then ok "python3" "$(python3 -V 2>&1 | awk '{print $2}')"
else warn "python3" "--patchset, and evidence/severity-calibration.py" "install python3"; fi

if command -v curl >/dev/null 2>&1; then ok "curl" ""
else warn "curl" "fetching the ground-truth corpus" "install curl"; fi

_hr=$(ls "${HOSTED_REVIEWS:-/nonexistent}"/*.json 2>/dev/null | wc -l)
if [ "$_hr" -gt 0 ]; then ok "hosted review corpus" "$_hr patchsets"
else warn "hosted review corpus" "scoring against published reviews (section 7), --patchset" \
        "$REVIEW_REPO/corpus/fetch-sashiko-hosted.sh"; fi

if [ -n "${SASHIKO_SRC:-}" ] && [ -x "$SASHIKO_SRC/target/release/sashiko" ]; then
    ok "Sashiko binary" "$SASHIKO_SRC/target/release/sashiko"
else
    warn "Sashiko binary" "harness/ comparison runs against real Sashiko" \
         "set SASHIKO_SRC to a checkout and run: cargo build --release"
fi

# ------------------------------------------------------------------ result ---
echo
if [ "$MISSING_REQ" -eq 0 ]; then
    echo "RESULT: ready to review."
    exit 0
fi
echo "RESULT: $MISSING_REQ required item(s) missing -- do not start a review."
echo "        Ask the user to arrange the items marked [MISSING] above."
exit 1
