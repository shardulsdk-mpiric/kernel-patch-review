#!/usr/bin/env bash
# Site-local paths for the review capability.
#
# Everything here can be overridden by an environment variable of the same
# name, or by an untracked config.local.sh sitting beside this file. Nothing
# in skill/ or harness/ may hardcode an absolute path -- the whole point of
# this file is that the repo can be cloned anywhere by anyone.
REVIEW_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The kernel tree under review.
: "${KERNEL_TREE:=/mnt/work_4gb/Dev/mpiric_kernel_dev_env/open/src/kernel/linux}"
# Where review worktrees are created.
: "${REVIEW_WORKROOT:=$KERNEL_TREE/.claude/worktrees}"
# Sashiko's prompt bundle -- the corpus the skill defers to (severity.md,
# false-positive-guide.md, ...). Read-only as far as the skill is concerned.
: "${SASHIKO_PROMPTS:=/mnt/work_4gb/Dev/mpiric_kernel_dev_env/open/src/ai_reviewers/samikshaka/local_llm/prompts-mptcp/kernel}"
# Hosted Sashiko reviews used as ground truth. Refetchable; see evidence/.
: "${HOSTED_REVIEWS:=/mnt/work_4gb/Dev/mpiric_kernel_dev_env/open/src/ai_reviewers/samikshaka/corpus/data/sashiko-hosted/mptcp/reviews}"
# Root of the samikshaka program tree (corpus, local_llm, sashiko mirror).
: "${SAMIKSHAKA_ROOT:=/mnt/work_4gb/Dev/mpiric_kernel_dev_env/open/src/ai_reviewers/samikshaka}"
# Where review transcripts and reports are written.
: "${REVIEW_RUNS:=$REVIEW_REPO/runs}"
# Verified bench trees built by harness/prepare-bench-tree.sh.
: "${BENCH_TREES:=/mnt/work_4gb/Dev/mpiric_kernel_dev_env/open/src/ai_reviewers/samikshaka/bench_trees}"

[ -f "$REVIEW_REPO/config.local.sh" ] && . "$REVIEW_REPO/config.local.sh"
export SAMIKSHAKA_ROOT REVIEW_RUNS REVIEW_REPO KERNEL_TREE REVIEW_WORKROOT SASHIKO_PROMPTS HOSTED_REVIEWS BENCH_TREES
