#!/usr/bin/env bash
# Site-local paths for the review capability.
#
# Every value here can be overridden by an environment variable of the same
# name, or by an untracked config.local.sh sitting beside this file. Nothing
# in this repo may hardcode a path that is true on only one machine -- the
# defaults below are derived from the repo, discovered on disk, or XDG.
#
# After sourcing this, a script that needs a path calls kpr_require to fail
# with a message naming the variable instead of proceeding on an empty value.

REVIEW_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- the kernel tree under review ----------------------------------------
# Discovered: the working directory, or the enclosing git checkout, if either
# looks like a kernel tree. Left empty otherwise -- reviewing the wrong tree
# silently is worse than refusing to start.
kpr_is_kernel_tree() {
    [ -n "${1:-}" ] && [ -f "$1/Makefile" ] && [ -f "$1/MAINTAINERS" ] && [ -d "$1/kernel" ]
}
if [ -z "${KERNEL_TREE:-}" ]; then
    KERNEL_TREE=""
    for _kpr_cand in "$PWD" "$(git rev-parse --show-toplevel 2>/dev/null)"; do
        if kpr_is_kernel_tree "$_kpr_cand"; then KERNEL_TREE="$_kpr_cand"; break; fi
    done
    unset _kpr_cand
fi

# --- Sashiko's prompt bundle ---------------------------------------------
# The corpus SKILL.md defers to: severity.md, false-positive-guide.md, and the
# subsystem/ files. Discovered at Sashiko's own install location, newest first.
# Point this at a checkout's third_party/prompts/kernel if you keep it there.
if [ -z "${SASHIKO_PROMPTS:-}" ]; then
    SASHIKO_PROMPTS="$(ls -dt "${XDG_DATA_HOME:-$HOME/.local/share}"/sashiko/prompts/*/kernel 2>/dev/null | head -1)"
fi

# --- a Sashiko source checkout -------------------------------------------
# Only harness/ needs this (it runs the real Sashiko binary for comparison
# runs). The skill itself never uses it.
: "${SASHIKO_SRC:=}"
: "${SASHIKO_SETTINGS:=${SASHIKO_SRC:+$SASHIKO_SRC/.claude/sashiko-local.toml}}"

# --- hosted reviews used as ground truth ---------------------------------
# One JSON per patchset, refetched from the public sashiko.dev API. Not
# shipped with this repo; see evidence/README.md for how to populate it.
: "${HOSTED_REVIEWS:=$REVIEW_REPO/corpus/sashiko-hosted/mptcp/reviews}"

# --- writable locations ---------------------------------------------------
: "${REVIEW_WORKROOT:=${KERNEL_TREE:+$KERNEL_TREE/.claude/worktrees}}"
: "${REVIEW_RUNS:=$REVIEW_REPO/runs}"
: "${REVIEW_STATE:=${XDG_STATE_HOME:-$HOME/.local/state}/kernel-patch-review}"
: "${BENCH_TREES:=${XDG_CACHE_HOME:-$HOME/.cache}/kernel-patch-review/bench-trees}"

# --- what schedule-review.sh fires ---------------------------------------
# Override to run your own wrapper. Default: this repo's Sashiko runner, with
# whatever arguments were passed through.
: "${REVIEW_LAUNCH_CMD:=$REVIEW_REPO/harness/sashiko-review.sh}"

[ -f "$REVIEW_REPO/config.local.sh" ] && . "$REVIEW_REPO/config.local.sh"

# kpr_require VAR [hint] -- abort unless VAR names an existing path.
kpr_require() {
    local _v="$1" _hint="${2:-}" _val
    eval "_val=\${$_v:-}"
    if [ -z "$_val" ]; then
        echo "$_v is not set. Set it in config.local.sh or the environment." >&2
        [ -n "$_hint" ] && echo "  $_hint" >&2
        exit 2
    fi
    if [ ! -e "$_val" ]; then
        echo "$_v points at a path that does not exist: $_val" >&2
        [ -n "$_hint" ] && echo "  $_hint" >&2
        exit 2
    fi
}

export REVIEW_REPO KERNEL_TREE SASHIKO_PROMPTS SASHIKO_SRC SASHIKO_SETTINGS \
       HOSTED_REVIEWS REVIEW_WORKROOT REVIEW_RUNS REVIEW_STATE BENCH_TREES \
       REVIEW_LAUNCH_CMD
