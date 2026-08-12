#!/usr/bin/env bash
# Run a local Sashiko review over a kernel tree using the Claude Code
# CLI provider (Claude Max subscription, no API-key billing).
#
# Why this wrapper exists:
#   1. `sashiko review` resolves the repo from the CWD, so it must be
#      run from inside the tree being reviewed -- not from the Sashiko
#      checkout. This handles the cd.
#   2. ANTHROPIC_API_KEY is set in Shardul's environment. The Claude
#      Code CLI PREFERS that key over the claude.ai/Max login, so every
#      `claude --print` Sashiko spawns would silently bill the API key
#      instead of the subscription. This unsets it for the run only.
#   3. It defaults --settings to the operator config in .claude/ rather
#      than the tracked upstream Settings.toml.
#
# Usage:
#   sashiko-review.sh [-n] [-r <repo>] [-s <settings>] [-p <prompts>] <range> [extra sashiko args...]
#
#   -n            dry run: pass --no-ai (validates patch extraction and
#                 application, costs zero quota). Do this first, always.
#   -r <repo>     tree to review (default: the kernel clone below)
#   -s <settings> settings file (default: .claude/sashiko-local.toml)
#   -p <prompts>  prompt bundle dir (sashiko --prompts). Use the trimmed
#                 MPTCP bundle to keep Phase 0 from loading 60+ subsystem
#                 guides into every turn's system prompt.
#
# Anything after <range> is passed straight through to sashiko. (An earlier
# version documented a "-- <sashiko args>" form that was never implemented:
# the args landed in $1 and were parsed as the range.)
#
# Examples:
#   sashiko-review.sh -n HEAD
#   sashiko-review.sh mptcp/export..HEAD
#   sashiko-review.sh -r /path/to/other/tree HEAD~3..HEAD
#
# Exit codes come from sashiko: 0 = clean, 1 = high/critical findings,
# 3 = review error. Nonzero is usually a result, not a crash.

set -euo pipefail
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/config.sh"

SASHIKO_DIR="$SAMIKSHAKA_ROOT/sashiko"
DEFAULT_REPO="$KERNEL_TREE"
BIN="${SASHIKO_DIR}/target/release/sashiko"

repo="${DEFAULT_REPO}"
settings="${SASHIKO_DIR}/.claude/sashiko-local.toml"
extra=()

while getopts ":nr:s:p:h" opt; do
  case "${opt}" in
    n) extra+=("--no-ai") ;;
    r) repo="${OPTARG}" ;;
    s) settings="${OPTARG}" ;;
    p) extra+=("--prompts" "${OPTARG}") ;;
    h) sed -n '2,32p' "$0"; exit 0 ;;
    \?) echo "unknown option -${OPTARG}" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

range="${1:-HEAD}"
shift $(( $# > 0 ? 1 : 0 ))
extra+=("$@")            # remaining args go straight to sashiko

[[ -x "${BIN}" ]] || { echo "sashiko binary missing: ${BIN} (cargo build --release)" >&2; exit 2; }
[[ -f "${settings}" ]] || { echo "settings file missing: ${settings}" >&2; exit 2; }
# Note: in a linked worktree .git is a FILE, not a directory -- ask git.
git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "not a git repo: ${repo}" >&2; exit 2; }

if pgrep -x sashiko >/dev/null 2>&1; then
  echo "warning: another sashiko process is running (port/db conflicts possible)" >&2
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "note: unsetting ANTHROPIC_API_KEY for this run so Claude Code uses" >&2
  echo "      the Max subscription instead of API-key billing" >&2
fi

if [[ -n "$(git -C "${repo}" status --porcelain --untracked-files=no)" ]]; then
  echo "warning: ${repo} has uncommitted tracked changes; the reviewer may see them" >&2
fi

echo "repo:     ${repo}"
echo "range:    ${range}"
echo "settings: ${settings}"
echo

cd "${repo}"
exec env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
  "${BIN}" review --settings "${settings}" "${extra[@]}" "${range}"
