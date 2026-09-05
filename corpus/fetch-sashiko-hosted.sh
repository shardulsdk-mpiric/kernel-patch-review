#!/usr/bin/env bash
# Copyright 2026 Shardul Bankar <shardul.b@mpiricsoftware.com>
# SPDX-License-Identifier: Apache-2.0
#
# Fetches the hosted Sashiko corpus for the MPTCP mailing list from
# sashiko.dev, so local review output can be scored against what the hosted
# instance actually said. This IS the ground truth for the primary objective.
#
# Discovered 2026-08-10: the hosted reviews are NOT on lore. `f:sashiko-bot`
# returns zero hits on lore.kernel.org/mptcp/. They live only in the web app,
# which is backed by the same JSON API Sashiko's own daemon serves
# (src/api.rs). The web UI at
#   https://sashiko.dev/#/?list=dev.linux.lists.mptcp
# is a client-side SPA over these endpoints:
#   GET /api/lists
#   GET /api/patchsets?mailing_list=<group>&page=N&per_page=<=100
#   GET /api/review?patchset_id=N
# Note the parameter is `mailing_list`, not `list` -- passing `list` is
# silently ignored and you get every list's patchsets back.
#
#   ./fetch-sashiko-hosted.sh                 # everything on the mptcp list
#   ./fetch-sashiko-hosted.sh --author <name>  # only that author's patchsets
#   ./fetch-sashiko-hosted.sh --with-logs     # keep the full stage logs (large)
#   ./fetch-sashiko-hosted.sh --index-only    # refresh the index, skip reviews

set -euo pipefail
cd "$(dirname "$0")"

# Layout is source-scoped so this corpus can hold more than one origin and
# more than one mailing list as the program grows:
#   corpus/<source>/<list>/{index.json,patchsets/,reviews/}
: "${SASHIKO_API:=https://sashiko.dev/api}"
: "${MAILING_LIST:=dev.linux.lists.mptcp}"
: "${CORPUS_SOURCE:=sashiko-hosted}"
: "${LIST_SHORTNAME:=${MAILING_LIST##*.}}"
: "${CORPUS_ROOT:=$(cd "$(dirname "$0")" && pwd)}"
: "${CORPUS_DIR:=${CORPUS_ROOT}/${CORPUS_SOURCE}/${LIST_SHORTNAME}}"
: "${CURL_TIMEOUT:=60}"

AUTHOR=""; WITH_LOGS=0; INDEX_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --author)     AUTHOR="${2:?--author needs a value}"; shift 2 ;;
    --with-logs)  WITH_LOGS=1; shift ;;
    --index-only) INDEX_ONLY=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

mkdir -p "${CORPUS_DIR}/patchsets" "${CORPUS_DIR}/reviews"

# ---------------------------------------------------------------- index ---
say "Fetching patchset index for ${MAILING_LIST}"
page=1
: > "${CORPUS_DIR}/.pages"
while :; do
  f="${CORPUS_DIR}/patchsets/page-${page}.json"
  code=$(curl -sS --max-time "${CURL_TIMEOUT}" -o "${f}" -w '%{http_code}' \
    "${SASHIKO_API}/patchsets?mailing_list=${MAILING_LIST}&per_page=100&page=${page}") || true
  [[ "${code}" == "200" ]] || { warn "page ${page}: HTTP ${code}, stopping"; rm -f "${f}"; break; }
  echo "${f}" >> "${CORPUS_DIR}/.pages"

  read -r got total < <(python3 -c "
import json,sys
d=json.load(open(sys.argv[1])); print(len(d.get('items',[])), d.get('total',0))
" "${f}")
  printf '    page %-3s %3s items (total %s)\n' "${page}" "${got}" "${total}"
  (( got > 0 )) || break
  (( page * 100 >= total )) && break
  page=$((page+1))
  (( page > 50 )) && { warn "stopping at 50 pages as a safety bound"; break; }
done

python3 - "${CORPUS_DIR}" "${AUTHOR}" <<'PY'
import json, glob, os, sys
corpus, author = sys.argv[1], (sys.argv[2] or '').lower()
seen = {}
for f in sorted(glob.glob(os.path.join(corpus, 'patchsets', 'page-*.json'))):
    try: d = json.load(open(f))
    except Exception: continue
    for i in d.get('items', []):
        seen[i['id']] = i
items = list(seen.values())
if author:
    items = [i for i in items if author in (i.get('author') or '').lower()]

def nf(i):
    return sum(i.get(f'findings_{k}', 0) or 0 for k in ('low','medium','high','critical'))

items.sort(key=lambda i: -i['id'])
json.dump(items, open(os.path.join(corpus, 'index.json'), 'w'), indent=1)
print(f"  indexed: {len(items)} patchsets"
      f"{f' by author~{author!r}' if author else ''}")
print(f"  with >=1 finding: {sum(1 for i in items if nf(i) > 0)}")
PY

(( INDEX_ONLY )) && { say "--index-only: done"; exit 0; }

# -------------------------------------------------------------- reviews ---
# WHICH ENDPOINT, AND WHY IT MATTERS (corrected 2026-08-10)
#
# Do NOT use /api/review?patchset_id=N here. Its handler is
# get_latest_review_for_patchset() -- singular, "latest". Reviews are per
# PATCH (each carries a patch_id), so a 3-patch series has 3 reviews and that
# endpoint silently returns one of them.
#
# The first version of this script did exactly that, and the damage was
# invisible: every file looked complete. It only surfaced when the per-severity
# counters in index.json disagreed with the fetched payload for 154 of 284
# patchsets. Measured on patchset 50269 (a 3-patch series): the single fetched
# review had 2 findings; the three real reviews have 2 + 2 + 3 = 7.
#
# /api/patchset?id=N returns patches[] AND reviews[] together, one review per
# patch, plus per-review tokens_in / tokens_out / tokens_cached.
say "Fetching per-patch reviews (skipping ones already on disk)"
python3 - "${CORPUS_DIR}" "${SASHIKO_API}" "${WITH_LOGS}" "${CURL_TIMEOUT}" <<'PY'
import json, os, subprocess, sys
corpus, api, with_logs, timeout = sys.argv[1], sys.argv[2], sys.argv[3] == '1', sys.argv[4]
items = json.load(open(os.path.join(corpus, 'index.json')))
outdir = os.path.join(corpus, 'reviews')
fetched = skipped = failed = 0

for n, it in enumerate(items, 1):
    pid = it['id']
    dest = os.path.join(outdir, f'{pid}.json')
    if os.path.exists(dest) and os.path.getsize(dest) > 2:
        skipped += 1
        continue
    r = subprocess.run(
        ['curl', '-sS', '--max-time', timeout, f'{api}/patchset?id={pid}'],
        capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        failed += 1
        print(f'    [{n}/{len(items)}] {pid}: FAILED', file=sys.stderr)
        continue
    try:
        rev = json.loads(r.stdout)
    except json.JSONDecodeError:
        failed += 1
        print(f'    [{n}/{len(items)}] {pid}: unparseable', file=sys.stderr)
        continue
    # `thread` (every message in the lore thread) and `baseline_logs` are bulky
    # and irrelevant to scoring; `logs` is not returned by this endpoint at all.
    if not with_logs and isinstance(rev, dict):
        for k in ('logs', 'thread', 'baseline_logs'):
            rev.pop(k, None)
    # Keep the patchset metadata alongside the review so each file is
    # self-contained and scoreable without re-joining against the index.
    # Shape note: `patchset` is the FULL /api/patchset response and carries
    # patches[] and reviews[] -- one review per patch, NOT a single review.
    # `index_entry` is the list-view metadata, kept because its per-severity
    # counters are computed differently from the payload and the disagreement
    # is itself a signal worth preserving rather than silently dropping.
    json.dump({'index_entry': it, 'patchset': rev}, open(dest, 'w'), indent=1)
    fetched += 1
    if fetched % 10 == 0:
        print(f'    [{n}/{len(items)}] fetched {fetched}')

print(f'  fetched {fetched}, already had {skipped}, failed {failed}')
PY

say "Corpus at ${CORPUS_DIR}"
say "  index.json   -- patchset metadata (subject, author, finding counts, model)"
say "  reviews/     -- one file per patchset: {patchset, review}"
