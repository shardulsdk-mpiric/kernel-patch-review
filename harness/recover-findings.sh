#!/usr/bin/env bash
# Recover stage findings from a run whose report never rendered.
#
#   ./recover-findings.sh <run-tag>
#
# Sashiko emits nothing when the final report stage fails, so a review that
# completed 11/11 stages can look like a total loss. It is not: every stage
# answer already passed through the logging proxy. Two runs that cost $15.12 and
# printed "report: 0 lines" in fact contained the findings, including two that
# matched the hosted reviewer.
#
# Report failures seen so far, all AFTER the analysis was done:
#   - stage 11 prompt exceeded the endpoint's max_prompt_tokens
#   - 402 Payment Required part-way through the report
#   - a panic in git_read_files (fixed, commit 4e03044)
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
TAG="${1:?usage: recover-findings.sh <run-tag>}"
B=${REVIEW_RUNS:-$REVIEW_REPO/runs}
D="$B/penalise_v1_${TAG}/proxy/replies"
[ -d "$D" ] || { echo "no proxy replies for ${TAG} at $D" >&2; exit 2; }

python3 - "$D" "$TAG" <<'PY'
import json,glob,re,sys
D,TAG=sys.argv[1],sys.argv[2]
allc=[];alld=[];valid=prose=0
for f in sorted(glob.glob(D+"/*.json")):
    try: d=json.load(open(f))
    except Exception: continue
    t=(d.get('message',{}).get('content') or '').strip()
    t=re.sub(r'^```json|```$','',t,flags=re.M).strip()
    try: o=json.loads(t)
    except Exception: prose+=1; continue
    if not isinstance(o,dict) or 'concerns' not in o: prose+=1; continue
    valid+=1
    allc+=o.get('concerns') or []
    alld+=o.get('dismissed_concerns') or []

print(f"# Recovered findings: {TAG}")
print(f"\n{valid} stage answers parsed as valid JSON, {prose} non-conforming "
      f"(prose instead of the required object -- those analyses are lost).\n")

def emit(title, items):
    print(f"## {title} ({len(items)} raw)")
    seen=set()
    for x in items:
        ttl=x.get('type') or x.get('title') or ''
        desc=(x.get('description') or x.get('problem') or '')
        k=(ttl,desc[:60])
        if k in seen: continue
        seen.add(k)
        loc=x.get('locations') or x.get('location') or []
        fn=loc[0].get('function_or_symbol','') if isinstance(loc,list) and loc and isinstance(loc[0],dict) else ''
        print(f"\n- **[{ttl}]** ({fn})\n  {desc[:400]}")
        r=x.get('reasoning') or x.get('why') or ''
        if r: print(f"  - reasoning: {r[:300]}")
    print(f"\n  ({len(items)-len(seen)} duplicates collapsed)\n")

emit("Concerns raised", allc)
if alld: emit("Dismissed", alld)
PY
